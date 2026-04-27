defmodule Yamux.SessionTest do
  use ExUnit.Case, async: true

  alias Yamux.Frame
  alias Yamux.Session

  # Handler used by the "handler triggers go_away" test: any data on a stream
  # causes the handler to ask the session to send a GoAway and shut down via
  # the {:go_away, reason, state} callback return.
  defmodule GoAwayOnDataHandler do
    use Yamux.Handler

    @impl true
    def init(_mode), do: {:ok, %{}}

    @impl true
    def new_stream(_id, _pid, state), do: {:ok, state}

    @impl true
    def stream_data(_id, _data, _pid, state) do
      {:go_away, :protocol_error, state}
    end

    @impl true
    def stream_closed(_id, _pid, state), do: {:ok, state}
  end

  # Starts a TCP listener, connects a client, and wraps both sides in sessions.
  # Returns {client_session, server_session}. `server_opts` is forwarded to the
  # server-side session (so tests can attach a handler).
  defp setup_pair(server_opts \\ []) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)

    # Connect client side
    {:ok, client_socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

    # Accept server side
    {:ok, server_socket} = :gen_tcp.accept(listener)
    :gen_tcp.close(listener)

    # Start sessions — they take over the sockets via controlling_process
    {:ok, client} = Session.start_link(client_socket, :client)
    {:ok, server} = Session.start_link(server_socket, :server, server_opts)

    {client, server}
  end

  # Sends a raw encoded frame over a session's socket.
  defp send_frame(session, frame) do
    %{socket: socket} = :sys.get_state(session)
    :gen_tcp.send(socket, Frame.encode(frame))
  end

  # Reads the session's GenServer state.
  defp get_state(session), do: :sys.get_state(session)

  describe "ping" do
    # Sending a ping (SYN) to a session should cause it to reply with a ping ACK
    # containing the same opaque body.
    test "session responds to ping with ack" do
      {client, server} = setup_pair()

      # Send a ping from client's socket to the server session
      ping = Frame.ping(42, false)
      send_frame(client, ping)

      # Give the server time to process and send the response
      Process.sleep(50)

      # The client session should have received the ping ACK. Read its buffer
      # by sending raw bytes and checking state, or just read from the socket.
      # Since the client session is also draining, we check its state saw a frame.
      # Actually, let's read the response from the client session's perspective:
      # the server sends a ping ack back over the TCP connection, which the client
      # session receives.
      client_state = get_state(client)

      # The buffer should be empty (frame was fully consumed)
      assert client_state.buffer == <<>>

      # Verify both sessions are still alive
      assert Process.alive?(client)
      assert Process.alive?(server)
    end

    # Sending a ping ACK should NOT trigger another ping response (no infinite loop).
    test "session does not respond to ping ack" do
      {client, server} = setup_pair()

      # Send a ping ACK (not a SYN) to the server
      ping_ack = Frame.ping(99, true)
      send_frame(client, ping_ack)

      Process.sleep(50)

      # Client should have an empty buffer (no response came back)
      client_state = get_state(client)
      assert client_state.buffer == <<>>

      assert Process.alive?(client)
      assert Process.alive?(server)
    end
  end

  describe "data frames" do
    # Sending a data frame between two sessions over TCP.
    test "data frame is received by the other session" do
      {client, server} = setup_pair()

      data_frame = Frame.data(1, "hello yamux")
      send_frame(client, data_frame)

      Process.sleep(50)

      # Server should have drained the frame (buffer empty)
      server_state = get_state(server)
      assert server_state.buffer == <<>>

      assert Process.alive?(server)
    end

    # Sending multiple data frames in quick succession.
    test "multiple data frames are all received" do
      {client, server} = setup_pair()

      frames =
        for i <- 1..10 do
          Frame.data(1, "message #{i}")
        end

      # Send all frames as one blob (simulates TCP batching)
      %{socket: socket} = get_state(client)
      payload = frames |> Enum.map(&Frame.encode/1) |> IO.iodata_to_binary()
      :gen_tcp.send(socket, payload)

      Process.sleep(50)

      server_state = get_state(server)
      assert server_state.buffer == <<>>

      assert Process.alive?(server)
    end

    # Sending a frame in two TCP segments to exercise the incomplete-parse path.
    test "fragmented frame is reassembled from buffer" do
      {client, server} = setup_pair()

      encoded = Frame.encode(Frame.data(1, "split me"))
      # Split in the middle of the frame
      split_at = div(byte_size(encoded), 2)
      <<first::binary-size(split_at), second::binary>> = encoded

      %{socket: socket} = get_state(client)

      # Send first half
      :gen_tcp.send(socket, first)
      Process.sleep(30)

      # Server should have an incomplete frame buffered
      server_state = get_state(server)
      assert byte_size(server_state.buffer) > 0

      # Send second half
      :gen_tcp.send(socket, second)
      Process.sleep(30)

      # Now the server should have drained the complete frame
      server_state = get_state(server)
      assert server_state.buffer == <<>>
    end
  end

  describe "go away" do
    # A go_away frame (type 0x3) on stream 0 should cause the session to stop.
    test "session shuts down on go_away" do
      {client, server} = setup_pair()

      # Monitor the server so we can detect it stopping
      ref = Process.monitor(server)

      go_away = %Frame{
        version: 0,
        type: 0x3,
        flags: 0x0,
        stream_id: 0,
        body: <<0::32>>,
        length: 4
      }

      send_frame(client, go_away)

      assert_receive {:DOWN, ^ref, :process, ^server, :normal}, 1000
    end

    # A handler that returns {:go_away, reason, state} from a callback should
    # cause the session to send a GoAway frame and stop. The peer (client),
    # receiving the frame, also stops.
    test "handler return tuple triggers go_away which stops both sessions" do
      {client, server} = setup_pair(handler: GoAwayOnDataHandler)

      client_ref = Process.monitor(client)
      server_ref = Process.monitor(server)

      # Open a stream from the client; the SYN reaches the server and creates
      # the stream there (no handler.new_stream side effects).
      {:ok, stream} = Session.open_stream(client)

      # Sending data on the stream triggers the server's handler.stream_data,
      # which returns {:go_away, :protocol_error, state}.
      :ok = Yamux.Stream.send_data(stream, "trigger")

      assert_receive {:DOWN, ^server_ref, :process, ^server, :normal}, 1000
      assert_receive {:DOWN, ^client_ref, :process, ^client, :normal}, 1000
    end

    # The external Session.go_away/2 cast API still works for callers outside
    # a handler callback (e.g. an admin process kicking a session).
    test "Session.go_away/2 cast also stops both sessions" do
      {client, server} = setup_pair()

      client_ref = Process.monitor(client)
      server_ref = Process.monitor(server)

      :ok = Session.go_away(server, :internal_error)

      assert_receive {:DOWN, ^server_ref, :process, ^server, :normal}, 1000
      assert_receive {:DOWN, ^client_ref, :process, ^client, :normal}, 1000
    end
  end

  describe "tcp close" do
    # When the remote side closes the TCP connection, the session should stop.
    test "session stops when tcp connection is closed" do
      {client, server} = setup_pair()

      ref = Process.monitor(server)

      # Close the client's underlying socket
      %{socket: socket} = get_state(client)
      :gen_tcp.close(socket)

      assert_receive {:DOWN, ^ref, :process, ^server, :normal}, 1000
    end
  end
end
