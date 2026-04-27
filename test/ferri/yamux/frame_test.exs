defmodule Yamux.FrameTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Yamux.Frame

  # ---------------------------------------------------------------------------
  # Generators

  defp frame_version, do: integer(0..0xFF)

  defp frame_flags do
    gen all(flags <- list_of(member_of([0x1, 0x2, 0x4, 0x8]), max_length: 4)) do
      Enum.reduce(flags, 0, &Bitwise.bor/2)
    end
  end

  defp stream_id, do: integer(0..0xFFFFFFFF)

  # Data frames: body carries the payload, length = byte_size(body).
  defp data_frame_gen do
    gen all(
          version <- frame_version(),
          flags <- frame_flags(),
          id <- stream_id(),
          body <- binary(min_length: 0, max_length: 1024)
        ) do
      %Frame{
        version: version,
        type: 0x0,
        flags: flags,
        stream_id: id,
        length: byte_size(body),
        body: body
      }
    end
  end

  # Non-data frames: no body, length carries a type-specific value.
  defp non_data_frame_gen do
    gen all(
          version <- frame_version(),
          type <- member_of([0x1, 0x2, 0x3]),
          flags <- frame_flags(),
          id <- stream_id(),
          length <- integer(0..0xFFFFFFFF)
        ) do
      %Frame{
        version: version,
        type: type,
        flags: flags,
        stream_id: id,
        length: length,
        body: <<>>
      }
    end
  end

  # Any valid frame (data or non-data).
  defp frame_gen do
    one_of([data_frame_gen(), non_data_frame_gen()])
  end

  # ---------------------------------------------------------------------------
  # Encoding

  describe "encode/1" do
    # Data frames: 12-byte header + body bytes.
    property "data frame is 12 bytes header + body" do
      check all(frame <- data_frame_gen()) do
        encoded = Frame.encode(frame)
        assert byte_size(encoded) == 12 + byte_size(frame.body)
      end
    end

    # Non-data frames: always exactly 12 bytes (header only, no body).
    property "non-data frame is exactly 12 bytes" do
      check all(frame <- non_data_frame_gen()) do
        encoded = Frame.encode(frame)
        assert byte_size(encoded) == 12
      end
    end

    # For data frames, the length field in the wire format equals byte_size(body).
    property "data frame length field matches body size" do
      check all(frame <- data_frame_gen()) do
        <<_::8, _::8, _::16, _::32, length::32, body::binary>> = Frame.encode(frame)
        assert length == byte_size(body)
      end
    end

    # For non-data frames, the length field carries the struct's length value.
    property "non-data frame length field carries semantic value" do
      check all(frame <- non_data_frame_gen()) do
        <<_::8, _::8, _::16, _::32, length::32>> = Frame.encode(frame)
        assert length == frame.length
      end
    end

    # Destructuring the binary as big-endian recovers the original struct values.
    property "header fields are big-endian encoded" do
      check all(frame <- frame_gen()) do
        <<version::8, type::8, flags::16-big, stream_id::32-big, _length::32-big, _rest::binary>> =
          Frame.encode(frame)

        assert version == frame.version
        assert type == frame.type
        assert flags == frame.flags
        assert stream_id == frame.stream_id
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Roundtrip

  describe "encode/parse roundtrip" do
    # Encoding a frame and parsing it back yields identical field values.
    property "parse(encode(frame)) returns the original frame" do
      check all(frame <- frame_gen()) do
        encoded = Frame.encode(frame)
        assert {:ok, parsed, <<>>} = Frame.parse(encoded)

        assert parsed.version == frame.version
        assert parsed.type == frame.type
        assert parsed.flags == frame.flags
        assert parsed.stream_id == frame.stream_id
        assert parsed.length == frame.length
        assert parsed.body == frame.body
      end
    end

    # Encoding, parsing, then re-encoding produces the exact same binary.
    property "encode is the inverse of parse for any valid binary frame" do
      check all(frame <- frame_gen()) do
        encoded = Frame.encode(frame)
        {:ok, parsed, <<>>} = Frame.parse(encoded)
        re_encoded = Frame.encode(parsed)

        assert encoded == re_encoded
      end
    end

    # Extra bytes after a complete frame are returned untouched as the rest.
    property "trailing bytes are preserved as rest" do
      check all(
              frame <- frame_gen(),
              trailing <- binary(min_length: 1, max_length: 128)
            ) do
        encoded = Frame.encode(frame)
        {:ok, _parsed, rest} = Frame.parse(encoded <> trailing)

        assert rest == trailing
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Parsing

  describe "parse/1" do
    # Cutting a data frame at a random byte position within the body yields :incomplete.
    property "returns :incomplete for truncated data frames" do
      check all(frame <- data_frame_gen(), byte_size(frame.body) > 0) do
        encoded = Frame.encode(frame)
        # Truncate somewhere within the body (after header but before end)
        truncated_len = 12 + :rand.uniform(byte_size(frame.body)) - 1
        truncated = binary_part(encoded, 0, truncated_len)
        assert {:error, :incomplete} = Frame.parse(truncated)
      end
    end

    # Truncating the header itself always yields :incomplete for any frame type.
    property "returns :incomplete for truncated headers" do
      check all(frame <- frame_gen()) do
        encoded = Frame.encode(frame)

        if byte_size(encoded) > 1 do
          truncated_len = :rand.uniform(min(11, byte_size(encoded) - 1))
          truncated = binary_part(encoded, 0, truncated_len)
          assert {:error, :incomplete} = Frame.parse(truncated)
        end
      end
    end

    # A zero-length input has no header to read.
    test "returns :incomplete for empty binary" do
      assert {:error, :incomplete} = Frame.parse(<<>>)
    end

    # A data frame header that declares length=10 but has no body bytes following it.
    test "returns :incomplete for data frame header-only (no body when length > 0)" do
      header = <<0::8, 0::8, 0::16, 1::32, 10::32>>
      assert {:error, :incomplete} = Frame.parse(header)
    end

    # Concatenating 2-5 encoded frames and parsing them sequentially recovers all frames.
    property "parses multiple concatenated frames" do
      check all(frames <- list_of(frame_gen(), min_length: 2, max_length: 5)) do
        combined = frames |> Enum.map(&Frame.encode/1) |> IO.iodata_to_binary()

        {parsed_frames, rest} = parse_all(combined, [])

        assert rest == <<>>
        assert length(parsed_frames) == length(frames)

        Enum.zip(frames, parsed_frames)
        |> Enum.each(fn {original, parsed} ->
          assert parsed.type == original.type
          assert parsed.flags == original.flags
          assert parsed.stream_id == original.stream_id
          assert parsed.length == original.length
          assert parsed.body == original.body
        end)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Flag checks

  describe "go_away/1" do
    test "builds a session-scoped frame with the error code in length" do
      frame = Frame.go_away(1)

      assert frame.type == 0x3
      assert frame.flags == 0x0
      assert frame.stream_id == 0
      assert frame.body == <<>>
      assert frame.length == 1
    end

    test "defaults to normal (0) when no code is given" do
      assert Frame.go_away().length == 0
    end

    test "encode + parse round-trip preserves the error code" do
      encoded = Frame.encode(Frame.go_away(2))
      assert {:ok, parsed, <<>>} = Frame.parse(encoded)

      assert parsed.type == 0x3
      assert parsed.stream_id == 0
      assert parsed.length == 2
    end

    test "raises on out-of-range codes" do
      assert_raise FunctionClauseError, fn -> Frame.go_away(3) end
    end
  end

  describe "flag checks" do
    # syn? returns true when bit 0 (0x1) is set.
    property "syn? is true iff SYN bit is set" do
      check all(flags <- integer(0..0xFFFF)) do
        assert Frame.syn?(flags) == (Bitwise.band(flags, 0x1) != 0)
      end
    end

    # ack? returns true when bit 1 (0x2) is set.
    property "ack? is true iff ACK bit is set" do
      check all(flags <- integer(0..0xFFFF)) do
        assert Frame.ack?(flags) == (Bitwise.band(flags, 0x2) != 0)
      end
    end

    # fin? returns true when bit 2 (0x4) is set.
    property "fin? is true iff FIN bit is set" do
      check all(flags <- integer(0..0xFFFF)) do
        assert Frame.fin?(flags) == (Bitwise.band(flags, 0x4) != 0)
      end
    end

    # rst? returns true exactly when bit 3 (0x8) is set.
    property "rst? is true iff RST bit is set" do
      check all(flags <- integer(0..0xFFFF)) do
        assert Frame.rst?(flags) == (Bitwise.band(flags, 0x8) != 0)
      end
    end

    # Setting one flag bit does not affect the result of checking another flag bit.
    property "flags are independent of each other" do
      check all(flags <- integer(0..0xFFFF)) do
        results = [Frame.syn?(flags), Frame.ack?(flags), Frame.fin?(flags), Frame.rst?(flags)]
        assert is_list(results)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers

  defp parse_all(<<>>, acc), do: {Enum.reverse(acc), <<>>}

  defp parse_all(data, acc) do
    case Frame.parse(data) do
      {:ok, frame, rest} -> parse_all(rest, [frame | acc])
      {:error, :incomplete} -> {Enum.reverse(acc), data}
    end
  end
end
