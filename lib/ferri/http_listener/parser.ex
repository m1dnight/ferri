defmodule Ferri.HttpListener.Parser do
  @moduledoc """
  Pure functions for parsing the prelude of an incoming HTTP/1.x request.

  The listener reads raw bytes off a TCP socket; this module turns those bytes
  into the small pieces the listener needs to route the request (end-of-headers
  detection, `Host:` header extraction, subdomain extraction). Nothing here
  touches sockets or processes, so it's trivially testable.
  """

  @header_terminator "\r\n\r\n"

  @doc """
  Returns `true` once `buffer` contains the end-of-headers sentinel `\\r\\n\\r\\n`.
  """
  @spec headers_complete?(binary()) :: boolean()
  def headers_complete?(buffer) when is_binary(buffer) do
    byte_size(buffer) >= 4 and :binary.match(buffer, @header_terminator) != :nomatch
  end

  @doc """
  Extracts the `Host:` header value from a raw header block, stripping any
  trailing `:port` suffix. Header-name matching is case-insensitive.
  """
  @spec extract_host(binary()) :: {:ok, String.t()} | :error
  def extract_host(header_bytes) when is_binary(header_bytes) do
    header_bytes
    |> String.split("\r\n")
    |> Enum.find_value(:error, fn line ->
      case String.split(line, ":", parts: 2) do
        [name, value] ->
          if String.downcase(name) == "host",
            do: {:ok, value |> String.trim() |> strip_port()},
            else: nil

        _ ->
          nil
      end
    end)
  end

  @doc """
  Extracts the leftmost label of a hostname, lowercased.

  E.g. `"Foo.example.com"` -> `"foo"`.
  """
  @spec subdomain(String.t()) :: String.t()
  def subdomain(host) when is_binary(host) do
    host |> String.split(".") |> hd() |> String.downcase()
  end

  @spec strip_port(String.t()) :: String.t()
  defp strip_port(host), do: host |> String.split(":") |> hd()
end
