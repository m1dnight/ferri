defmodule Ferri.Tunnel.HttpListener do
  @moduledoc """
  Visitor-facing HTTP listener.

  Accepts raw TCP connections, parses the `Host:` header out of the request
  prelude, looks up the owning yamux session in `Ferri.Tunnel.Registry`, opens
  a fresh yamux stream to the client, forwards the bytes it has already read,
  then shuttles bytes bidirectionally between the visitor's TCP socket and the
  yamux stream until either side closes.

  This stays at the byte level on purpose — Plug/Bandit would buffer the full
  request and break streaming / future WebSocket upgrades.
  """

  use GenServer

  alias Ferri.Tunnel.Registry

  require Logger

  @max_header_bytes 8 * 1024
  @recv_timeout 30_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    port = Keyword.fetch!(opts, :port)

    {:ok, listener} =
      :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true])

    Logger.info("HTTP listener started on port #{port}")

    {:ok, %{listener: listener}, {:continue, :accept}}
  end

  @impl true
  def handle_continue(:accept, state) do
    case :gen_tcp.accept(state.listener) do
      {:ok, socket} ->
        {:ok, pid} =
          Task.start(fn ->
            receive do
              {:socket, s} -> handle_connection(s)
            end
          end)

        :ok = :gen_tcp.controlling_process(socket, pid)
        send(pid, {:socket, socket})

        {:noreply, state, {:continue, :accept}}

      {:error, :closed} ->
        Logger.info("HTTP listener closed")
        {:stop, :normal, state}
    end
  end

  # -- Per-connection handling ------------------------------------------------

  defp handle_connection(socket) do
    case read_until_headers(socket, <<>>) do
      {:ok, header_bytes} ->
        route(socket, header_bytes)

      {:error, :too_large} ->
        respond_error(socket, 431, "Request Header Fields Too Large")

      {:error, reason} ->
        Logger.debug("HTTP visitor read failed: #{inspect(reason)}")
        :gen_tcp.close(socket)
    end
  end

  # Read from the socket until we've seen the end of the HTTP headers
  # (\r\n\r\n), bailing if we exceed @max_header_bytes.
  @spec read_until_headers(:gen_tcp.socket(), binary()) ::
          {:ok, binary()} | {:error, :too_large | term()}
  defp read_until_headers(_socket, buffer) when byte_size(buffer) > @max_header_bytes do
    {:error, :too_large}
  end

  defp read_until_headers(socket, buffer) do
    if byte_size(buffer) >= 4 and :binary.match(buffer, "\r\n\r\n") != :nomatch do
      {:ok, buffer}
    else
      case :gen_tcp.recv(socket, 0, @recv_timeout) do
        {:ok, data} -> read_until_headers(socket, buffer <> data)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp route(socket, header_bytes) do
    case extract_host(header_bytes) do
      {:ok, host} ->
        subdomain = host |> String.split(".") |> hd() |> String.downcase()

        case Registry.lookup(subdomain) do
          {:ok, session_pid} ->
            proxy(socket, session_pid, header_bytes, subdomain)

          :error ->
            Logger.debug("No tunnel registered for subdomain #{inspect(subdomain)}")
            respond_error(socket, 502, "Bad Gateway")
        end

      :error ->
        respond_error(socket, 400, "Bad Request")
    end
  end

  @spec extract_host(binary()) :: {:ok, String.t()} | :error
  defp extract_host(header_bytes) do
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

  defp strip_port(host), do: host |> String.split(":") |> hd()

  # -- Proxy loop -------------------------------------------------------------

  defp proxy(socket, session_pid, header_bytes, subdomain) do
    Logger.info("Proxying visitor request to tunnel #{subdomain}")

    case Yamux.Session.open_stream(session_pid) do
      {:ok, stream_pid} ->
        case Yamux.Stream.send_data(stream_pid, header_bytes) do
          :ok ->
            run_proxy(socket, stream_pid)

          {:error, reason} ->
            Logger.debug("Failed to write headers to stream: #{inspect(reason)}")
            :gen_tcp.close(socket)
        end
    end
  end

  defp run_proxy(socket, stream_pid) do
    parent = self()

    sock_to_stream =
      spawn_link(fn ->
        forward_socket_to_stream(socket, stream_pid)
        send(parent, :done)
      end)

    stream_to_sock =
      spawn_link(fn ->
        forward_stream_to_socket(stream_pid, socket)
        send(parent, :done)
      end)

    # Wait for either direction to finish, then tear both sides down.
    receive do
      :done -> :ok
    end

    Process.exit(sock_to_stream, :kill)
    Process.exit(stream_to_sock, :kill)
    Yamux.Stream.close(stream_pid)
    :gen_tcp.close(socket)
  end

  defp forward_socket_to_stream(socket, stream_pid) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, data} ->
        case Yamux.Stream.send_data(stream_pid, data) do
          :ok -> forward_socket_to_stream(socket, stream_pid)
          {:error, _} -> :ok
        end

      {:error, _} ->
        :ok
    end
  end

  defp forward_stream_to_socket(stream_pid, socket) do
    case Yamux.Stream.recv(stream_pid, 0) do
      {:ok, data} ->
        case :gen_tcp.send(socket, data) do
          :ok -> forward_stream_to_socket(stream_pid, socket)
          {:error, _} -> :ok
        end

      {:error, _} ->
        :ok
    end
  end

  # -- Error responses --------------------------------------------------------

  defp respond_error(socket, status, reason) do
    body = "#{status} #{reason}\n"

    response =
      "HTTP/1.1 #{status} #{reason}\r\n" <>
        "Content-Type: text/plain\r\n" <>
        "Content-Length: #{byte_size(body)}\r\n" <>
        "Connection: close\r\n" <>
        "\r\n" <>
        body

    _ = :gen_tcp.send(socket, response)
    :gen_tcp.close(socket)
  end
end
