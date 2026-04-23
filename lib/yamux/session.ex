defmodule Yamux.Session do
  @moduledoc """
  A GenServer that represents a Yamux session.

  A session maps 1:1 onto a single TCP connection. Over one session, multiple
  streams can be sent. So a session has to keep track of which streams are
  active.

  """
  use GenServer
  use TypedStruct

  alias Yamux.Frame
  alias Yamux.Session
  alias Yamux.Stream

  require Logger

  typedstruct enforce: true do
    field :socket, :inet.socket()
    field :mode, :client | :server
    field :buffer, binary(), default: <<>>
    field :streams, %{non_neg_integer() => pid()}, default: %{}
    field :next_stream_id, non_neg_integer()
    # Handler behaviour module and its opaque state
    field :handler, module() | nil, default: nil
    field :handler_state, term(), default: nil
  end

  @doc """
  Opens a new outbound stream on the session, returning the stream pid.

  Allocates the next stream id (odd for clients, even for servers), spawns the
  stream process, and sends a SYN frame to the peer.
  """
  @spec open_stream(pid()) :: {:ok, pid()}
  def open_stream(session), do: GenServer.call(session, :open_stream)

  def start_link(socket, mode, opts \\ []) do
    # First start the genserver that will manage this session.
    {:ok, pid} = GenServer.start_link(__MODULE__, {socket, mode, opts})
    # Transfer ownership of the socket to the genserver. This can only be done
    # by the owner of the socket (the caller of start_link), so this has to
    # happen with a two-step approach.
    :ok = :gen_tcp.controlling_process(socket, pid)

    # The socket has been handed over, signal this to the session process.
    send(pid, :socket_ready)

    {:ok, pid}
  end

  @impl true
  def init({socket, mode, opts}) do
    Logger.debug("Yamux session started")

    next_id = if mode == :client, do: 1, else: 2
    handler = Keyword.get(opts, :handler)

    handler_state =
      if handler do
        {:ok, hs} = handler.init(mode)
        hs
      end

    {:ok,
     %Session{
       socket: socket,
       mode: mode,
       next_stream_id: next_id,
       handler: handler,
       handler_state: handler_state
     }}
  end

  @impl true
  def handle_info(:socket_ready, state) do
    # We now own the socket, so we can start receiving a data message from it.
    :ok = :inet.setopts(state.socket, active: :once)
    {:noreply, state}
  end

  # raw bytes coming in over the TCP socket
  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    # Re-arm active mode for next data message. By setting it to once we only
    # receive 1 data message. To receive the next one we have to set it to once
    # again.
    :ok = :inet.setopts(socket, active: :once)

    # append the data message to the buffer and then try and drain it.
    state = %{state | buffer: state.buffer <> data}

    case drain_frames(state) do
      {:ok, session} ->
        {:noreply, session}

      {:error, :go_away, state} ->
        notify_streams(state, :session_closed)
        invoke_handler(state, :terminate, [:go_away])
        Logger.debug("Session terminating due to go away message")
        {:stop, :normal, :go_away}
    end
  end

  def handle_info({:tcp_closed, _socket}, state) do
    notify_streams(state, :session_closed)
    invoke_handler(state, :terminate, [:tcp_closed])
    Logger.debug("Session terminating; socket closed")
    {:stop, :normal, state}
  end

  @impl true
  def handle_call(:open_stream, _from, state) do
    id = state.next_stream_id
    {:ok, stream_pid} = Stream.start_link(self(), id)
    :ok = :gen_tcp.send(state.socket, Frame.encode(Frame.syn(id)))

    state = %{
      state
      | streams: Map.put(state.streams, id, stream_pid),
        next_stream_id: id + 2
    }

    {:reply, {:ok, stream_pid}, state}
  end

  @impl true
  def handle_cast({:send_raw, bytes}, state) do
    :ok = :gen_tcp.send(state.socket, bytes)
    {:noreply, state}
  end

  # Try and parse multiple frames from the buffer. If it succeeds, dispatch each
  # frame.
  @spec drain_frames(Session.t()) :: {:ok, Session.t()} | {:error, :go_away, Session.t()}
  defp drain_frames(state) do
    case Frame.parse(state.buffer) do
      {:ok, frame, rest} ->
        Logger.debug("SESSION > #{inspect(frame)}")
        state = %{state | buffer: rest}

        case dispatch_frame(frame, state) do
          # The message has been dispatched succesfully.
          {:ok, state} ->
            # keep draining, might be multiple frames
            drain_frames(state)

          # Encountered a go away message, stop the session.
          {:error, :go_away, state} ->
            {:error, :go_away, state}
        end

      {:error, :incomplete} ->
        {:ok, state}
    end
  end

  # if the stream id is 0, this means that this is a frame asking information
  # about the session, not the stream (i.e., ping and go away).
  @spec dispatch_frame(Frame.t(), Session.t()) ::
          {:ok, Session.t()} | {:error, :go_away, Session.t()}
  defp dispatch_frame(%Frame{stream_id: 0} = frame, state) do
    handle_session_frame(frame, state)
  end

  defp dispatch_frame(frame, state) do
    handle_stream_frame(frame, state)
  end

  # Handles a frame that is meant to be sent to a specific stream.
  defp handle_stream_frame(%Frame{stream_id: id, flags: flags} = frame, state) do
    # Dispatch on the stream message. This can be any of the following:
    # A new stream is initiated. This is a SYN message.
    cond do
      # New stream, and we dont know about this stream yet.
      Frame.syn?(flags) and not Map.has_key?(state.streams, id) ->
        {:ok, pid} = Stream.start_link(self(), id)
        send(pid, {:frame, frame})

        # acknowledge the new stream
        syn_ack = Frame.syn_ack(id)
        :ok = :gen_tcp.send(state.socket, Frame.encode(syn_ack))

        state = %{state | streams: Map.put(state.streams, id, pid)}
        state = invoke_handler(state, :new_stream, [id, pid])

        # SYN frames can carry data (piggybacked first write)
        state =
          if frame.type == 0x0 and byte_size(frame.body) > 0 do
            invoke_handler(state, :stream_data, [id, frame.body, pid])
          else
            state
          end

        {:ok, state}

      # The client sent a FIN message, meaning they want to half-close.
      Frame.fin?(flags) and Map.has_key?(state.streams, id) ->
        Logger.debug("Half-closing stream #{id}")
        pid = Map.get(state.streams, id)
        send(pid, {:frame, frame})
        state = invoke_handler(state, :stream_closed, [id, pid])
        {:ok, state}

      # RST — stream abruptly reset by remote
      Frame.rst?(flags) and Map.has_key?(state.streams, id) ->
        pid = Map.get(state.streams, id)
        send(pid, {:frame, frame})
        state = invoke_handler(state, :stream_error, [id, pid])
        {:ok, state}

      # The frame is directed at a currently existing stream
      Map.has_key?(state.streams, id) ->
        pid = Map.get(state.streams, id)
        send(pid, {:frame, frame})

        # Notify handler of data frames with body content
        state =
          if frame.type == 0x0 and byte_size(frame.body) > 0 do
            invoke_handler(state, :stream_data, [id, frame.body, pid])
          else
            state
          end

        {:ok, state}

      # We don't know this stream, it's data frame directed at a non-existing stream.
      true ->
        Logger.debug("Received frame for unknown stream #{id}, ignoring")
        {:ok, state}
    end
  end

  # If a session frame has flag 0x2, it's a ping message. If a session has frame
  # flag 0x3, it's a go away message.
  @spec handle_session_frame(Frame.t(), Session.t()) ::
          {:ok, Session.t()} | {:error, :go_away, Session.t()}
  defp handle_session_frame(%Frame{type: 0x2} = frame, state) do
    # PING — if not an ack, send one back
    unless Frame.ack?(frame.flags) do
      response = Frame.encode(Frame.ping(frame.length, true))
      _ = :gen_tcp.send(state.socket, response)
      :ok
    end

    state = invoke_handler(state, :ping, [frame.length])
    {:ok, state}
  end

  defp handle_session_frame(%Frame{type: 0x3}, state) do
    # GO_AWAY — shut down
    {:error, :go_away, state}
  end

  defp notify_streams(state, message) do
    Enum.each(state.streams, fn {_id, pid} -> send(pid, message) end)
  end

  # Invokes a handler callback if a handler is configured. For callbacks that
  # return {:ok, new_state}, the handler_state is updated. For :terminate,
  # the return value is ignored.
  defp invoke_handler(%{handler: nil} = state, _callback, _args), do: state

  defp invoke_handler(state, :terminate, args) do
    apply(state.handler, :terminate, args ++ [state.handler_state])
    state
  end

  defp invoke_handler(state, callback, args) do
    {:ok, new_hs} = apply(state.handler, callback, args ++ [state.handler_state])
    %{state | handler_state: new_hs}
  end
end
