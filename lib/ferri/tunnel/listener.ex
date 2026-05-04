defmodule Ferri.Tunnel.Listener do
  @moduledoc """
  TCP listener that accepts Rust client connections and establishes yamux
  sessions with the tunnel handler.
  """

  use GenServer

  require Logger

  alias Yamux.Session

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    port = Keyword.fetch!(opts, :port)
    rate_bps = Keyword.get(opts, :rate_bps, :infinity)
    burst_bytes = Keyword.get(opts, :burst_bytes, 0)

    # start the socket to listen for incoming web requests
    opts = [:binary, active: false, reuseaddr: true, exit_on_close: false]

    # if the socket fails to open, abort.
    case :gen_tcp.listen(port, opts) do
      {:ok, listen_socket} ->
        Logger.info("Tunnel listener started on port #{port}")

        # accept first connection
        send(self(), :accept)

        {:ok, %{socket: listen_socket, rate_bps: rate_bps, burst_bytes: burst_bytes}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(:accept, %{socket: listen_socket} = state) do
    case :gen_tcp.accept(listen_socket, 2_000) do
      {:ok, socket} ->
        # grab some extra information from the socket for logging
        {:ok, {ip, port}} = :inet.peername(socket)
        Logger.info("Tunnel client connected #{inspect(ip)}:#{inspect(port)}")

        # Start a connection process for this client's connection.
        {:ok, _session} =
          Session.start_link(socket, :server,
            handler: Ferri.Tunnel.Handler,
            rate_bps: state.rate_bps,
            burst_bytes: state.burst_bytes
          )

        # Accept next connection.
        send(self(), :accept)
        {:noreply, state}

      {:error, :timeout} ->
        send(self(), :accept)
        {:noreply, state}

      # todo: gracefully handle this case with the child Session processes.
      {:error, reason} ->
        {:stop, reason, state}
    end
  end
end
