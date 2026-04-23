defmodule Ferri.HttpListener.Parser do
  @moduledoc """
  Pure functions for parsing the prelude of an incoming HTTP/1.x request.
  """

  @typedoc """
  A single parsed HTTP header.
  """
  @type header :: {atom() | binary(), binary()}

  @doc """
  Attempt to parse the HTTP request line off the front of `buffer`.

  Returns `{:ok, rest}` with the remaining bytes (headers + body) if the
  request line was complete and well-formed, or `{:error, :not_valid_http}`
  otherwise.
  """
  @spec try_http_req(binary()) :: {:ok, binary()} | {:error, :not_valid_http}
  def try_http_req(buffer) do
    case :erlang.decode_packet(:http_bin, buffer, []) do
      # valid http request part
      {:ok, {:http_request, _method, _uri, _version}, rest} ->
        {:ok, rest}

      _ ->
        {:error, :not_valid_http}
    end
  end

  @doc """
  Parse HTTP headers out of `buffer` until the end-of-headers marker.

  Assumes the request line has already been consumed (see `try_http_req/1`).
  Returns `{:ok, headers}` once the end-of-headers has been reached. Returns
  `{:error, :not_valid_http}` if the buffer is incomplete or malformed.
  """
  @spec try_headers(binary(), [header()]) :: {:ok, [header()]} | {:error, :not_valid_http}
  def try_headers(buffer, headers \\ []) do
    case :erlang.decode_packet(:httph_bin, buffer, []) do
      {:ok, {:http_header, _, _header_atom, header, value}, rest} ->
        try_headers(rest, [{String.downcase(header), value} | headers])

      {:ok, :http_eoh, ""} ->
        {:ok, headers}

      _other ->
        {:error, :not_valid_http}
    end
  end
end
