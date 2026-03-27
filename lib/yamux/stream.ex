defmodule Yamux.Stream do
  @moduledoc """
  A GenServer representing a single logical yamux stream within a session.

  Each stream is a bidirectional byte channel multiplexed over a single TCP
  connection. Streams are identified by an integer ID assigned by the session.

  When a session receives frames for a stream, it will only send the body of the
  frames to the stream, so the stream deals with raw bytes only that were held
  inside the frames.

  ## Flow control

  Each stream maintains a send and receive window (default 256KB). The sender
  may not exceed the receiver's window. When the receive buffer is consumed, a
  `WINDOW_UPDATE` frame is sent to grant the remote more credit.

  ## Half-close

  Either side may close its send direction by sending a `FIN` flag. The stream
  remains open for receiving until the remote also sends `FIN`. Only when both
  sides have sent `FIN` is the stream fully closed.
  """

  use GenServer
  use TypedStruct

  alias Yamux.Frame
  alias Yamux.Stream

  import Bitwise

  require Logger

  @initial_window 262_144
  @low_window_threshold 131_072

  typedstruct enforce: true do
    @typedoc "Internal state of a yamux stream process."

    field :stream_id, non_neg_integer(), enforce: true
    field :session, pid(), enforce: true
    field :send_window, non_neg_integer(), default: @initial_window
    field :recv_window, non_neg_integer(), default: @initial_window
    field :recv_buffer, binary(), default: <<>>
    field :send_closed, boolean(), default: false
    field :recv_closed, boolean(), default: false
    field :recv_waiters, [{GenServer.from(), non_neg_integer()}], default: []
    field :send_waiters, [{GenServer.from(), binary()}], default: []
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Starts a stream GenServer linked to the current process.

  ## Parameters
  - `session` - PID of the parent `Ferri.Yamux.Session` process
  - `stream_id` - The yamux stream ID for this stream
  """
  @spec start_link(pid(), non_neg_integer()) :: GenServer.on_start()
  def start_link(session, stream_id) do
    GenServer.start_link(__MODULE__, {session, stream_id})
  end

  @doc """
  Sends data on the stream.

  Returns `{:error, :closed}` if the send side is already closed, or
  `{:error, :window_full}` if the remote's receive window is exhausted.
  """
  @spec send_data(pid(), binary()) :: :ok | {:error, :closed | :window_full}
  def send_data(pid, data), do: GenServer.call(pid, {:send, data})

  @doc """
  Receives data from the stream, blocking until data is available.

  If `length` is 0, returns all currently buffered bytes.
  If `length` is positive, blocks until at least that many bytes are available.
  Returns `{:error, :closed}` if the stream is closed with no buffered data.
  """
  @spec recv(pid(), non_neg_integer()) :: {:ok, binary()} | {:error, :closed}
  def recv(pid, length), do: GenServer.call(pid, {:recv, length}, :infinity)

  @doc """
  Half-closes the send side of the stream by sending a FIN frame.

  The stream remains open for receiving until the remote also sends FIN.
  """
  @spec close(pid()) :: :ok
  def close(pid), do: GenServer.cast(pid, :close)

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init({session, stream_id}) do
    {:ok, %Stream{session: session, stream_id: stream_id}}
  end

  @impl GenServer
  # Send data on the stream.
  def handle_call({:send, data}, from, state) do
    cond do
      state.send_closed ->
        {:reply, {:error, :closed}, state}

      # All data fits in the window — send immediately.
      byte_size(data) <= state.send_window ->
        frame = Frame.data(state.stream_id, data)
        send_frame(state, frame)
        {:reply, :ok, %{state | send_window: state.send_window - byte_size(data)}}

      # Data is larger than the window — send what fits, queue the rest.
      state.send_window > 0 ->
        <<chunk::binary-size(state.send_window), rest::binary>> = data
        send_frame(state, Frame.data(state.stream_id, chunk))
        {:noreply, %{state | send_window: 0, send_waiters: state.send_waiters ++ [{from, rest}]}}

      # Window is empty — queue everything until a window update arrives.
      true ->
        {:noreply, %{state | send_waiters: state.send_waiters ++ [{from, data}]}}
    end
  end

  @impl GenServer
  # Receive data from the stream.
  def handle_call({:recv, length}, from, state) do
    # Take the `length` bytes from the stream.
    case take_from_buffer(state.recv_buffer, length) do
      # There were `length` bytes in the buffer, return them and shrink the buffer.
      {:ok, data, rest} ->
        {:reply, {:ok, data}, %{state | recv_buffer: rest}}

      # There were not `length` bytes on the buffer. If the stream was closed,
      # return an error. If the stream is not closed, but not enough data was in
      # the stream yet, defer the return of the call and put the calling pid in
      # the queue of waiters.
      :insufficient ->
        if state.recv_closed do
          {:reply, {:error, :closed}, state}
        else
          {:noreply, %{state | recv_waiters: state.recv_waiters ++ [{from, length}]}}
        end
    end
  end

  @impl GenServer
  def handle_cast(:close, state) do
    # Close the stream by sending a FIN frame and setting send_closed to true.
    frame = Frame.fin(state.stream_id)
    send_frame(state, frame)
    {:noreply, %{state | send_closed: true}}
  end

  @impl GenServer
  def handle_info({:frame, %Frame{} = frame}, state) do
    Logger.debug("> #{inspect(frame)}")
    {:noreply, handle_frame(frame, state)}
  end

  def handle_info(:session_closed, state) do
    Logger.debug("Session closed by sender")

    Enum.each(state.recv_waiters, fn {from, _length} ->
      GenServer.reply(from, {:error, :closed})
    end)

    Enum.each(state.send_waiters, fn {from, _data} ->
      GenServer.reply(from, {:error, :closed})
    end)

    {:stop, :normal,
     %{state | send_closed: true, recv_closed: true, recv_waiters: [], send_waiters: []}}
  end

  def handle_info(message, state) do
    Logger.error("unhandled message in strem: #{inspect(message)}")
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Frame handling
  # ---------------------------------------------------------------------------

  @spec handle_frame(Frame.t(), t()) :: t()
  # Handle a data frame
  defp handle_frame(%Frame{type: 0x0} = frame, state) do
    state
    |> buffer_data(frame.body)
    |> decrement_recv_window(byte_size(frame.body))
    |> maybe_send_window_update()
    |> maybe_mark_recv_closed(frame)
    |> flush_recv_waiters()
  end

  # Handle a window_update frame.
  # The delta is carried in the length field of the header, not the body.
  defp handle_frame(%Frame{type: 0x1, length: delta}, state) do
    %{state | send_window: state.send_window + delta}
    |> flush_send_waiters()
  end

  # Handle a frame that has tha RST flag set. This signals that an error
  # occurred and the stream has to be closed instantly.
  defp handle_frame(%Frame{flags: flags}, state) when (flags &&& 0x8) != 0 do
    # RST — immediately close both directions
    %{state | send_closed: true, recv_closed: true}
  end

  defp handle_frame(_frame, state) do
    state
  end

  # ---------------------------------------------------------------------------
  # Buffer helpers
  # ---------------------------------------------------------------------------

  @spec buffer_data(t(), binary()) :: t()
  # Add the given data to the end of the data buffer.
  defp buffer_data(state, data) do
    %{state | recv_buffer: state.recv_buffer <> data}
  end

  @spec decrement_recv_window(t(), non_neg_integer()) :: t()
  # Reduce the receive window by the given amount of bytes.
  defp decrement_recv_window(state, bytes) do
    %{state | recv_window: state.recv_window - bytes}
  end

  @spec maybe_mark_recv_closed(t(), Frame.t()) :: t()
  # If the received frame has a FIN flag, we should flag the receiver as closed
  # so we can't send data anymore.
  defp maybe_mark_recv_closed(state, frame) do
    if Frame.fin?(frame.flags) do
      %{state | recv_closed: true}
    else
      state
    end
  end

  @spec maybe_send_window_update(t()) :: t()
  # Send a window update frame if the buffer is smaller than the low threshold initially set.
  # Automatically assume the window has been increased.
  defp maybe_send_window_update(state) when state.recv_window < @low_window_threshold do
    delta = @initial_window - state.recv_window
    frame = Frame.window_update(state.stream_id, delta)
    send_frame(state, frame)
    %{state | recv_window: state.recv_window + delta}
  end

  defp maybe_send_window_update(state), do: state

  # Take a specific amount of bytes, or all bytes from the buffer. 0 here means
  # "take it all", and will return :insufficient if the buffer is empty.
  @spec take_from_buffer(binary(), non_neg_integer()) ::
          {:ok, binary(), binary()} | :insufficient
  defp take_from_buffer(buffer, 0) do
    if byte_size(buffer) > 0 do
      {:ok, buffer, <<>>}
    else
      :insufficient
    end
  end

  defp take_from_buffer(buffer, length) do
    if byte_size(buffer) >= length do
      <<data::binary-size(length), rest::binary>> = buffer
      {:ok, data, rest}
    else
      :insufficient
    end
  end

  @spec flush_send_waiters(t()) :: t()
  defp flush_send_waiters(%{send_waiters: []} = state), do: state
  defp flush_send_waiters(%{send_window: 0} = state), do: state

  defp flush_send_waiters(state) do
    {remaining, new_state} =
      Enum.reduce(state.send_waiters, {[], state}, fn {from, data}, {unmet, st} ->
        cond do
          st.send_window == 0 ->
            {unmet ++ [{from, data}], st}

          byte_size(data) <= st.send_window ->
            send_frame(st, Frame.data(st.stream_id, data))
            GenServer.reply(from, :ok)
            {unmet, %{st | send_window: st.send_window - byte_size(data)}}

          true ->
            <<chunk::binary-size(st.send_window), rest::binary>> = data
            send_frame(st, Frame.data(st.stream_id, chunk))
            {unmet ++ [{from, rest}], %{st | send_window: 0}}
        end
      end)

    %{new_state | send_waiters: remaining}
  end

  @spec flush_recv_waiters(t()) :: t()
  # For all the waiting processes, fetch the amount of bytes they wanted, and
  # send them to them. When a waiter cannot be satisfied, it is put back in the
  # queue and the other waiters are tried to see if any of them can be
  # satisfied.
  defp flush_recv_waiters(%{recv_waiters: []} = state), do: state

  defp flush_recv_waiters(state) do
    {remaining, new_state} =
      Enum.reduce(state.recv_waiters, {[], state}, fn {from, length}, {unmet, state} ->
        case take_from_buffer(state.recv_buffer, length) do
          {:ok, data, rest} ->
            GenServer.reply(from, {:ok, data})
            {unmet, %{state | recv_buffer: rest}}

          :insufficient ->
            {unmet ++ [{from, length}], state}
        end
      end)

    %{new_state | recv_waiters: remaining}
  end

  # ---------------------------------------------------------------------------
  # Socket helper
  # ---------------------------------------------------------------------------

  # sends a raw frame across the socket.
  @spec send_frame(t(), Frame.t()) :: :ok
  defp send_frame(state, frame) do
    Logger.debug("< #{inspect(frame)}")
    encoded = Frame.encode(frame)
    GenServer.cast(state.session, {:send_raw, encoded})
    Logger.debug("Frame sent")
  end
end
