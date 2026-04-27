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

  @typedoc "GoAway error code per the yamux spec."
  @type go_away_reason :: :normal | :protocol_error | :internal_error

  @doc """
  Sends a GoAway frame to the peer and stops the session. Safe to call from
  inside a `Yamux.Handler` callback (it is async — the frame is sent and the
  session stops on the next dispatch).
  """
  @spec go_away(GenServer.server(), go_away_reason()) :: :ok
  def go_away(session, reason \\ :normal) do
    GenServer.cast(session, {:go_away, reason})
  end

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

      # Peer sent us a GoAway — just tear down, no frame to emit.
      {:error, :go_away, state} ->
        notify_streams(state, :session_closed)
        invoke_terminate(state, :go_away)
        Logger.debug("Session terminating due to go away message")
        {:stop, :normal, :go_away}

      # Handler asked us to send a GoAway — emit it, then tear down.
      {:error, {:go_away, reason}, state} ->
        frame = Frame.encode(Frame.go_away(go_away_code(reason)))
        _ = :gen_tcp.send(state.socket, frame)
        notify_streams(state, :session_closed)
        invoke_terminate(state, :go_away)
        Logger.debug("Session terminating; handler asked for GoAway (#{reason})")
        {:stop, :normal, state}
    end
  end

  def handle_info({:tcp_closed, _socket}, state) do
    notify_streams(state, :session_closed)
    invoke_terminate(state, :tcp_closed)
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

  def handle_cast({:go_away, reason}, state) do
    frame = Frame.encode(Frame.go_away(go_away_code(reason)))
    _ = :gen_tcp.send(state.socket, frame)

    notify_streams(state, :session_closed)
    invoke_terminate(state, :go_away)
    Logger.debug("Session terminating; sent GoAway (#{reason})")
    {:stop, :normal, state}
  end

  # Result of processing one TCP buffer's worth of frames.
  @typep drain_result ::
           {:ok, Session.t()}
           | {:error, :go_away, Session.t()}
           | {:error, {:go_away, Yamux.Handler.go_away_reason()}, Session.t()}

  # Try and parse multiple frames from the buffer. If it succeeds, dispatch each
  # frame.
  @spec drain_frames(Session.t()) :: drain_result()
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
          {:error, _, _} = halt ->
            halt
        end

      {:error, :incomplete} ->
        {:ok, state}
    end
  end

  # if the stream id is 0, this means that this is a frame asking information
  # about the session, not the stream (i.e., ping and go away).
  @spec dispatch_frame(Frame.t(), Session.t()) :: drain_result()
  defp dispatch_frame(%Frame{stream_id: 0} = frame, state) do
    handle_session_frame(frame, state)
  end

  defp dispatch_frame(frame, state) do
    handle_stream_frame(frame, state)
  end

  # Handles a frame that is meant to be sent to a specific stream.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
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

        # Invoke the handler for a new stream, and if the SYN had data, pass
        # that as well.
        with {:ok, state} <- invoke_handler(state, :new_stream, [id, pid]) do
          maybe_run_stream_data(state, frame, id, pid)
        end

      # The client sent a FIN message, meaning they want to half-close.
      Frame.fin?(flags) and Map.has_key?(state.streams, id) ->
        Logger.debug("Half-closing stream #{id}")
        pid = Map.get(state.streams, id)
        send(pid, {:frame, frame})
        invoke_handler(state, :stream_closed, [id, pid])

      # RST — stream abruptly reset by remote
      Frame.rst?(flags) and Map.has_key?(state.streams, id) ->
        pid = Map.get(state.streams, id)
        send(pid, {:frame, frame})
        invoke_handler(state, :stream_error, [id, pid])

      # The frame is directed at a currently existing stream
      Map.has_key?(state.streams, id) ->
        pid = Map.get(state.streams, id)
        send(pid, {:frame, frame})
        maybe_run_stream_data(state, frame, id, pid)

      # We don't know this stream, it's data frame directed at a non-existing stream.
      true ->
        Logger.debug("Received frame for unknown stream #{id}, ignoring")
        {:ok, state}
    end
  end

  # SYN and DATA frames can both carry a body. Only invoke :stream_data if there is one.
  defp maybe_run_stream_data(state, %Frame{type: 0x0, body: body}, id, pid)
       when byte_size(body) > 0 do
    invoke_handler(state, :stream_data, [id, body, pid])
  end

  defp maybe_run_stream_data(state, _frame, _id, _pid), do: {:ok, state}

  # If a session frame has type 0x2, it's a ping message. Type 0x3 is a peer-
  # initiated go away.
  @spec handle_session_frame(Frame.t(), Session.t()) :: drain_result()
  defp handle_session_frame(%Frame{type: 0x2} = frame, state) do
    # PING — if not an ack, send one back
    _ =
      if not Frame.ack?(frame.flags) do
        response = Frame.encode(Frame.ping(frame.length, true))
        :gen_tcp.send(state.socket, response)
      end

    invoke_handler(state, :ping, [frame.length])
  end

  defp handle_session_frame(%Frame{type: 0x3}, state) do
    # GO_AWAY — shut down
    {:error, :go_away, state}
  end

  defp notify_streams(state, message) do
    Enum.each(state.streams, fn {_id, pid} -> send(pid, message) end)
  end

  # Calls a handler callback and converts its return into the same {:ok, state}
  # / {:error, {:go_away, reason}, state} channel that drain_frames threads
  # back to handle_info.
  @spec invoke_handler(Session.t(), atom(), [term()]) :: drain_result()
  defp invoke_handler(%{handler: nil} = state, _callback, _args), do: {:ok, state}

  defp invoke_handler(state, callback, args) do
    case apply(state.handler, callback, args ++ [state.handler_state]) do
      {:ok, new_hs} ->
        {:ok, %{state | handler_state: new_hs}}

      {:go_away, reason, new_hs} ->
        {:error, {:go_away, reason}, %{state | handler_state: new_hs}}
    end
  end

  # `:terminate` doesn't follow the callback_return contract — its return is
  # ignored and it can't ask the (already-terminating) session to stop.
  defp invoke_terminate(%{handler: nil}, _reason), do: :ok

  defp invoke_terminate(state, reason) do
    state.handler.terminate(reason, state.handler_state)
    # _ = apply(state.handler, :terminate, [reason, state.handler_state])
    :ok
  end

  defp go_away_code(:normal), do: 0
  defp go_away_code(:protocol_error), do: 1
  defp go_away_code(:internal_error), do: 2
end
