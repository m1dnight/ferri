defmodule Ferri.HttpListener.Connection do
  @moduledoc """
  Per-visitor GenServer that owns one visitor TCP socket for its lifetime.

  On the first request, the connection parses enough of the HTTP prelude to
  extract the `Host:` header, looks up the matching yamux session in
  `Ferri.Tunnel.Registry`, opens a yamux stream to that session, and forwards
  the raw buffered bytes onto the stream. From that point on, bytes flow
  through in both directions without further HTTP parsing — the TCP connection
  is bound to one session for its lifetime.

  A linked task (`listen_to_stream/2`) drives the reverse direction, reading
  from the yamux stream and forwarding via `{:stream_data, data}` messages
  that the GenServer writes out to the TCP socket.
  """

  use TypedStruct
  use GenServer

  alias Ferri.HttpListener.Connection
  alias Ferri.HttpListener.Parser
  alias Ferri.Statistics
  alias Ferri.Tunnel.Registry

  require Logger

  typedstruct enforce: true do
    field :socket, :inet.socket()
    field :buffer, binary(), default: <<>>
    field :session, pid() | nil, default: nil
    field :session_name, String.t() | nil, default: nil
    field :stream, pid() | nil, default: nil
    field :proxy, pid() | nil, default: nil
  end

  @spec start_link(:gen_tcp.socket()) :: GenServer.on_start()
  def start_link(socket) do
    GenServer.start_link(Connection, socket)
  end

  @impl true
  def init(socket) do
    Logger.debug("New client process started")
    state = %Connection{socket: socket}
    {:ok, state}
  end

  @impl true
  def handle_info({:tcp, socket, data}, %Connection{socket: socket} = state) do
    Logger.debug("New data on socket")
    :ok = :inet.setopts(socket, active: :once)
    {:ok, {ip, port}} = :inet.peername(socket)
    Logger.info("new conn from #{:inet.ntoa(ip)}:#{port} (pid=#{inspect(self())})")
    state = update_in(state.buffer, &(&1 <> data))

    case handle_new_data(state) do
      {:ok, state} ->
        {:noreply, state}

      {:error, err} ->
        Logger.debug("Invalid session, dropping connection #{inspect(err)}")
        tear_down(state)
        {:stop, :normal, state}
    end
  end

  def handle_info({:tcp_closed, socket}, %Connection{socket: socket} = state) do
    Logger.debug("Client closed connection")
    tear_down(state)
    {:stop, :normal, state}
  end

  def handle_info({:tcp_error, socket, reason}, %Connection{socket: socket} = state) do
    Logger.error("TCP connection error: #{inspect(reason)}")
    tear_down(state)

    {:stop, :normal, state}
  end

  def handle_info({:stream_data, bytes}, %Connection{socket: socket} = state) do
    :ok = :gen_tcp.send(socket, bytes)
    Statistics.bump_down(byte_size(bytes))
    {:noreply, state}
  end

  def handle_info(m, state) do
    Logger.debug("Unhandled message: #{inspect(m)}")
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------#
  #                                Helpers                                     #
  # ---------------------------------------------------------------------------#

  # we assume here that one tcp connection will always have the same host
  # header. This means that the first request that is sent will determine the
  # session to which to route the requests.
  #
  # We parse the first time until we can determine a session, once we have that,
  # we can simply pipe the raw bytes through to the client.
  @spec handle_new_data(t()) ::
          {:ok, t()} | {:error, :invalid_request | :invalid_session}
  defp handle_new_data(%{session: nil} = state) do
    with {:ok, rest} <- Parser.try_http_req(state.buffer),
         {:ok, headers} <- Parser.try_headers(rest),
         {"host", host} <- List.keyfind(headers, "host", 0, :no_header),
         {:ok, name, pid} <- fetch_session(host) do
      Logger.debug("New session for #{name}")
      # update state with session and new buffer
      state = put_in(state.session, pid)
      state = put_in(state.session_name, name)

      {:ok, flush_to_session(state)}
    else
      {:error, :not_valid_http} ->
        Logger.debug("Not a valid http request")
        {:error, :invalid_request}

      {:error, :no_session_active} ->
        Logger.debug("Not an active session")
        {:error, :invalid_session}

      :no_header ->
        Logger.debug("No host header found")
        {:error, :invalid_request}
    end
  end

  defp handle_new_data(state) do
    {:ok, flush_to_session(state)}
  end

  # fetch the session from the registry if there exists one
  @spec fetch_session(binary()) ::
          {:ok, String.t(), pid()} | {:error, :invalid_host}
  defp fetch_session(host) do
    with {:ok, session_name} <- extract_session_name(host),
         {:ok, session_pid} <- Registry.lookup(session_name) do
      {:ok, session_name, session_pid}
    else
      _ ->
        {:error, :invalid_host}
    end
  end

  # extracts the session name from the host header value
  @spec extract_session_name(binary()) ::
          {:ok, String.t()} | {:error, :invalid_host}
  defp extract_session_name(host) do
    # the host is in the shape of prefix.host, so trim the host
    case String.split(host, ".", parts: 2) do
      [host, _] ->
        {:ok, host}

      _ ->
        {:error, :invalid_host}
    end
  end

  # Push the current buffer onto the yamux stream. On the first call (no stream
  # open yet) we open one on the session and start the reverse-direction task.
  @spec flush_to_session(t()) :: t()
  defp flush_to_session(%{stream: nil} = state) do
    with {:ok, stream} <- Yamux.Session.open_stream(state.session),
         :ok <- Yamux.Stream.send_data(stream, state.buffer) do
      Statistics.bump_up(byte_size(state.buffer))
      # start a process that will send incoming data from the stream onto the socket
      state = put_in(state.stream, stream)
      {:ok, proxy} = start_stream_listener(state)
      state = put_in(state.buffer, <<>>)
      state = put_in(state.proxy, proxy)

      state
    end
  end

  defp flush_to_session(state) do
    :ok = Yamux.Stream.send_data(state.stream, state.buffer)
    Statistics.bump_up(byte_size(state.buffer))
    put_in(state.buffer, <<>>)
  end

  # spawns an async task that will forward all messages from the yamux stream to
  # this socket controller
  @spec start_stream_listener(t()) :: {:ok, pid()}
  defp start_stream_listener(state) do
    this = self()
    Task.start_link(fn -> listen_to_stream(state.stream, this) end)
  end

  # listens to a yamux stream and forwards the data to the connection for putting it on the socket
  @spec listen_to_stream(pid(), pid()) :: :ok
  defp listen_to_stream(stream, handler) do
    case Yamux.Stream.recv(stream, 0) do
      {:ok, data} ->
        send(handler, {:stream_data, data})
        listen_to_stream(stream, handler)

      {:error, _} ->
        Logger.error("Stream listenering terminating")
        :ok
    end
  end

  # tears down the connection
  # disconnect tpc and disconnect the yamux stream
  defp tear_down(state) do
    Logger.debug("Tearing down connection")
    :gen_tcp.close(state.socket)
    Yamux.Stream.close(state.stream)

    if state.proxy do
      Process.exit(state.proxy, :exit)
    end
  end
end
