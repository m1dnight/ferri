defmodule Ferri.Tunnel.HandlerTest do
  use ExUnit.Case, async: true

  alias Ferri.Tunnel.Handler

  # State with the control stream wired up. We never exercise the control_pid
  # in these tests (the cap kicks in before any reply is sent), so self() is
  # fine.
  defp control_state do
    %Handler{
      control_stream: {1, self()},
      buffer: <<>>,
      subdomain: nil,
      session_pid: nil
    }
  end

  describe "control buffer cap" do
    test "oversized length header triggers a protocol_error go_away" do
      state = control_state()

      # 4 GB length — only 4 header bytes need to arrive for the cap to fire.
      data = <<0xFFFFFFFF::32>>

      assert {:go_away, :protocol_error, new_state} =
               Handler.stream_data(1, data, self(), state)

      assert new_state.buffer == <<>>
    end

    test "length one byte over the cap (129) triggers go_away" do
      state = control_state()
      data = <<129::32-big>>

      assert {:go_away, :protocol_error, _} =
               Handler.stream_data(1, data, self(), state)
    end

    test "fewer than 4 buffer bytes does not trigger go_away (header incomplete)" do
      state = control_state()

      # Only 3 bytes — drain falls through to the catch-all and buffers.
      data = <<0xFF, 0xFF, 0xFF>>

      assert {:ok, new_state} = Handler.stream_data(1, data, self(), state)
      assert new_state.buffer == data
    end
  end

  describe "control message parsing" do
    test "invalid JSON within the cap triggers go_away" do
      state = control_state()

      json = "not json at all"
      data = <<byte_size(json)::32-big, json::binary>>

      assert {:go_away, :protocol_error, new_state} =
               Handler.stream_data(1, data, self(), state)

      assert new_state.buffer == <<>>
    end

    test "data on a non-control stream is ignored" do
      state = control_state()

      assert {:ok, ^state} = Handler.stream_data(2, "anything", self(), state)
    end
  end

  describe "buffering across calls" do
    # A frame that arrives in two TCP chunks (partial header on the first
    # call, rest of header + body on the second) must be reassembled. We use
    # an "unknown" message type so handle_control_message takes its no-op
    # catch-all branch — that way we don't need the Registry running.
    test "frame split across two stream_data calls is reassembled" do
      json = ~s({"type":"unknown"})
      full = <<byte_size(json)::32-big, json::binary>>

      <<chunk1::binary-size(2), chunk2::binary>> = full

      # First chunk: only 2 bytes — header is incomplete, drain buffers it.
      assert {:ok, after_first} =
               Handler.stream_data(1, chunk1, self(), control_state())

      assert after_first.buffer == chunk1

      # Second chunk: completes the header + body. drain parses, dispatches,
      # and the catch-all then resets the buffer.
      assert {:ok, after_second} =
               Handler.stream_data(1, chunk2, self(), after_first)

      assert after_second.buffer == <<>>
    end

    # Two complete frames glued together in a single TCP segment must both be
    # drained in one call (drain_control_messages recurses on the rest).
    test "back-to-back frames in one call are both drained" do
      frame = fn json ->
        <<byte_size(json)::32-big, json::binary>>
      end

      data = frame.(~s({"type":"unknown"})) <> frame.(~s({"type":"other"}))

      assert {:ok, new_state} =
               Handler.stream_data(1, data, self(), control_state())

      assert new_state.buffer == <<>>
    end
  end

  describe "new_stream/3" do
    # The first stream the peer opens is, by convention, the control stream.
    test "first stream becomes the control stream" do
      state = %Handler{}
      pid = spawn(fn -> :ok end)

      assert {:ok, new_state} = Handler.new_stream(7, pid, state)
      assert new_state.control_stream == {7, pid}
    end

    # Subsequent streams (visitor streams) must NOT overwrite control_stream.
    test "subsequent streams do not overwrite the control stream" do
      original = control_state()
      pid = spawn(fn -> :ok end)

      assert {:ok, ^original} = Handler.new_stream(99, pid, original)
    end
  end

  describe "terminate/2" do
    # If the session dies before registering, there's nothing to clean up.
    # The guard around Registry.unregister/1 means this should not even touch
    # the Registry — proven implicitly: no Registry is running in this test.
    test "is a no-op when subdomain is nil" do
      assert :ok == Handler.terminate(:tcp_closed, %Handler{subdomain: nil})
    end
  end
end
