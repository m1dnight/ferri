defmodule Yamux.Frame do
  @moduledoc """
  Defines the structure of a Yamux frame.

  In Yamux, a single TCP connection is called a session. Over a single session,
  multiple streams are multiplexed. This avoids the overhead of having multiple
  TCP connections for multiple data streams. A single session can contain
  multiple streams, each with a unique ID.

  ┌─────────────────────────────────────────────┐
  │              TCP Connection                 │
  │             (Yamux Session)                 │
  │                                             │
  │  ┌──────────┐ ┌──────────┐ ┌──────────┐     │
  │  │ Stream 1 │ │ Stream 2 │ │ Stream 3 │ ... │
  │  │  (ID=1)  │ │  (ID=2)  │ │  (ID=3)  │     │
  │  └──────────┘ └──────────┘ └──────────┘     │
  └─────────────────────────────────────────────┘

  Within a single stream, Yamux frames are being sent back and forth.
  A Yamux frame contains the following header:

  +---------+--------+----------+-----------------+-----------------+
  | Version | Type   | Flags    | Stream ID       | Length          |
  | (8 bit) | (8 bit)| (16 bit) | (32 bit)        | (32 bit)        |
  +---------+--------+----------+-----------------+-----------------+

   - **Version** The version field is used for backward compatibility. It
     contains the version of the Yamux protocol. Currently always 0.

   - **Type** The type field contains the type of the of the frame message. The
     following types exist:

      - 0x0 Data: used to transmit data
      - 0x1 Window Update: Update the sender's receive window size. Allows
        implementing flow control. The receive window size tells the sender how
        much bytes they are allowed to send before they have to wait.
      - 0x2 Ping: Used to measure round-trip-time.
      - 0x3 Go Away: Used to close a session.

   - **Flags** The flag is used to provide extra information about the message
     type. The following flags exist:

      - 0x1 SYN: Signals the start of a new stream.
      - 0x2 ACK: Acknowledges the start of a new stream, or passed with a ping
        response.
      - 0x4 FIN: Performs half-close. This signals that one side is done sending,
        but will still receive data.
      - 0x8 RST: Resets a stream immediately. This is sent when the stream is
        aborted abruptly. More extreme than FIN.

   - **Stream ID** The stream id is used to identify which logical stream these
     frames belong to. Clients always use odd ids, and servers always use even
     ids. Session id 0 is used to query status of the whole session, not a
     particular stream.

   - **Length** The lenght field can be used to hold multiple types of
     information depending on the type of the message:

      - Data: provides the length of the bytes that follow this header.
      - Window Update: provides a delta update to the window size (increase)
      - Ping: contains an arbitrary value that is sent back
      - Go Away: contains an error code


  Note: all fields are big endian encoded.

  Spec: https://github.com/hashicorp/yamux/blob/master/spec.md
  """
  import Bitwise

  alias Yamux.Frame

  use TypedStruct

  # Frame types
  @data 0x0
  @window_update 0x1
  @ping 0x2
  @go_away 0x3

  # Flags
  @syn 0x1
  @ack 0x2
  @fin 0x4
  @rst 0x8

  # Default window size from spec (256 kb)
  # @initial_window 262_144

  typedstruct enforce: true do
    field :version, non_neg_integer()
    field :type, non_neg_integer()
    field :flags, non_neg_integer()
    field :stream_id, non_neg_integer()
    field :body, binary()
    field :length, non_neg_integer()
  end

  # Convenience flag checks
  def syn?(flag), do: band(flag, @syn) != 0
  def ack?(flag), do: band(flag, @ack) != 0
  def fin?(flag), do: band(flag, @fin) != 0
  def rst?(flag), do: band(flag, @rst) != 0

  @doc """
  Attempts to parse one frame from a binary buffer.
  Returns {:ok, frame, rest} if a complete frame is available,
  or {:incomplete} if more bytes are needed.
  """
  @spec parse(binary()) :: {:ok, Frame.t(), binary()} | {:error, :incomplete}
  def parse(frame) do
    case frame do
      # Data frames: length indicates the number of body bytes that follow.
      <<v::8-big, @data::8-big, flags::16-big, id::32-big, length::32-big,
        body::binary-size(length), rest::binary>> ->
        {:ok,
         %Frame{
           version: v,
           type: @data,
           flags: flags,
           stream_id: id,
           length: length,
           body: body
         }, rest}

      # Non-data frames: no body follows the header. The length field carries
      # a type-specific value (delta, opaque ping value, error code).
      <<v::8-big, type::8-big, flags::16-big, id::32-big, length::32-big, rest::binary>>
      when type != @data ->
        {:ok,
         %Frame{
           version: v,
           type: type,
           flags: flags,
           stream_id: id,
           length: length,
           body: <<>>
         }, rest}

      _ ->
        {:error, :incomplete}
    end
  end

  @doc """
  Encodes a struct into a bitstring.
  """
  @spec encode(Frame.t()) :: binary()
  # Data frames: length = byte_size(body), followed by body bytes.
  def encode(%Frame{type: @data, version: v, flags: flags, stream_id: id, body: body}) do
    <<v::8-big, @data::8, flags::16-big, id::32-big, byte_size(body)::32-big, body::binary>>
  end

  # Non-data frames: length carries a type-specific value, no body follows.
  def encode(%Frame{version: v, type: type, flags: flags, stream_id: id, length: length}) do
    <<v::8-big, type::8, flags::16-big, id::32-big, length::32-big>>
  end

  @doc """
  Takes in a frame body that was sent as a ping, and returns a new frame that is
  the response to this ping.

  A response is a frame of type 0x2, stream id 0, and the same body as the ping
  message.

  If the message is an ACK of a ping, the flag is set to 0x2 (ack) otherwise 0x1
  (syn).
  """
  @spec ping(non_neg_integer(), boolean()) :: Frame.t()
  def ping(opaque \\ 0, ack \\ false) do
    flags = if ack, do: @ack, else: @syn

    %Frame{
      type: @ping,
      flags: flags,
      stream_id: 0,
      body: <<>>,
      length: opaque,
      version: 0
    }
  end

  @doc """
  Creates a new data frame to be sent out over a session for a specific stream.

  The flags for a data packet are set to 0x0 by default.
  """
  @spec data(non_neg_integer(), binary()) :: Frame.t()
  def data(stream_id, data) do
    %Frame{
      type: @data,
      flags: 0x0,
      stream_id: stream_id,
      body: data,
      length: byte_size(data),
      version: 0
    }
  end

  @doc """
  Creates a new fin frame to be sent out over the stream.

  > To close a stream, either side sends a data or window update frame along
  > with the FIN flag. This does a half-close indicating the sender will send no
  > further data.
  """
  @spec fin(non_neg_integer()) :: Frame.t()
  def fin(stream_id) do
    %Frame{
      type: @data,
      flags: @fin,
      stream_id: stream_id,
      body: <<>>,
      length: 0,
      version: 0
    }
  end

  @doc """
  Creates a new window update frame to ask the receiver/sender for a larger window.
  """
  @spec window_update(non_neg_integer(), non_neg_integer()) :: Frame.t()
  def window_update(stream_id, delta) do
    %Frame{
      type: @window_update,
      flags: 0x0,
      stream_id: stream_id,
      body: <<>>,
      length: delta,
      version: 0
    }
  end

  @doc """
  Creates an ACK frame to signal the socket accepts the stream.
  """
  @spec syn_ack(non_neg_integer()) :: Frame.t()
  def syn_ack(stream_id) do
    %Frame{
      type: @data,
      flags: @ack,
      stream_id: stream_id,
      body: <<>>,
      length: 0,
      version: 0
    }
  end

  @doc """
  Creates a SYN frame to open a new outbound stream.
  """
  @spec syn(non_neg_integer()) :: Frame.t()
  def syn(stream_id) do
    %Frame{
      type: @data,
      flags: @syn,
      stream_id: stream_id,
      body: <<>>,
      length: 0,
      version: 0
    }
  end

  @doc """
  Creates a GoAway frame asking the peer to terminate the session. The error
  code travels in the length field per the yamux spec:

  * `0` — normal termination
  * `1` — protocol error
  * `2` — internal error
  """
  # the success type is a subtype of the spec, but i dont know how to fix it properly
  @dialyzer {:nowarn_function, go_away: 1}
  @spec go_away(0 | 1 | 2) :: Frame.t()
  def go_away(code \\ 0) when code in 0..2 do
    %Frame{
      type: @go_away,
      flags: 0x0,
      stream_id: 0,
      body: <<>>,
      length: code,
      version: 0
    }
  end

  defimpl Inspect do
    import Inspect.Algebra

    @type_names %{0x0 => "DATA", 0x1 => "WINDOW_UPDATE", 0x2 => "PING", 0x3 => "GO_AWAY"}
    @flag_bits [
      {0x1, "SYN"},
      {0x2, "ACK"},
      {0x4, "FIN"},
      {0x8, "RST"}
    ]

    def inspect(frame, opts) do
      type_name = Map.get(@type_names, frame.type, "UNKNOWN")

      flags_str =
        @flag_bits
        |> Enum.filter(fn {bit, _} -> Bitwise.band(frame.flags, bit) != 0 end)
        |> Enum.map_join("|", fn {_, name} -> name end)
        |> case do
          "" -> "0"
          str -> str
        end

      body_hex =
        frame.body
        |> Base.encode16(case: :lower)
        |> case do
          hex when byte_size(hex) > 32 -> binary_part(hex, 0, 32) <> "..."
          hex -> hex
        end

      inner =
        concat([
          "v=#{frame.version}",
          " type=#{type_name}(0x#{Integer.to_string(frame.type, 16)})",
          " flags=#{flags_str}(0b#{Integer.to_string(frame.flags, 2)})",
          " stream=#{frame.stream_id}",
          " len=#{frame.length}",
          " body=0x#{body_hex}"
        ])

      container_doc("#Frame<", [inner], ">", opts, fn doc, _opts -> doc end)
    end
  end
end
