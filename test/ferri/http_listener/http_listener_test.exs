defmodule Ferri.Tunnel.HttpListenerTest do
  @moduledoc """
  Integration tests for the visitor-facing TCP listener.

  The listener is started by the application supervisor, bound to an
  OS-assigned port in the `:test` environment (see `config/test.exs`). These
  tests connect as a real TCP client and exercise the per-connection
  `Ferri.HttpListener.Connection` echo loop end-to-end.
  """

  use ExUnit.Case, async: false

  @connect_opts [:binary, active: false]
  @recv_timeout 500

  setup_all do
    # The GenServer's state is the listen socket itself.
    listen_socket = :sys.get_state(Ferri.Tunnel.HttpListener)
    {:ok, port} = :inet.port(listen_socket)
    {:ok, port: port}
  end

  test "echoes a single line back", %{port: port} do
    {:ok, socket} = :gen_tcp.connect(~c"localhost", port, @connect_opts)

    assert :ok = :gen_tcp.send(socket, "Hello world\n")
    assert {:ok, "Hello world\n"} = :gen_tcp.recv(socket, 0, @recv_timeout)

    :gen_tcp.close(socket)
  end

  test "handles fragmented data across multiple sends", %{port: port} do
    {:ok, socket} = :gen_tcp.connect(~c"localhost", port, @connect_opts)

    assert :ok = :gen_tcp.send(socket, "Hello")
    assert :ok = :gen_tcp.send(socket, " world\nand one more\n")

    assert {:ok, data} = recv_all(socket, "Hello world\nand one more\n")
    assert data == "Hello world\nand one more\n"

    :gen_tcp.close(socket)
  end

  test "handles multiple clients simultaneously", %{port: port} do
    tasks =
      for _ <- 1..5 do
        Task.async(fn ->
          {:ok, socket} = :gen_tcp.connect(~c"localhost", port, @connect_opts)
          assert :ok = :gen_tcp.send(socket, "Hello world\n")
          assert {:ok, "Hello world\n"} = :gen_tcp.recv(socket, 0, @recv_timeout)
          :gen_tcp.close(socket)
        end)
      end

    Task.await_many(tasks)
  end

  test "echoes only complete lines, buffering a partial trailing line", %{port: port} do
    {:ok, socket} = :gen_tcp.connect(~c"localhost", port, @connect_opts)

    assert :ok = :gen_tcp.send(socket, "one\ntwo")

    # The "one\n" line should come back; "two" stays buffered server-side.
    assert {:ok, "one\n"} = :gen_tcp.recv(socket, 0, @recv_timeout)
    assert {:error, :timeout} = :gen_tcp.recv(socket, 0, 100)

    # Once we flush the trailing newline, the buffered chunk comes through.
    assert :ok = :gen_tcp.send(socket, "\n")
    assert {:ok, "two\n"} = :gen_tcp.recv(socket, 0, @recv_timeout)

    :gen_tcp.close(socket)
  end

  # OS-level buffering can split a single logical payload across multiple
  # packets, so recv/3 may need to be called more than once. Loops until we've
  # collected exactly `expected`, or times out.
  defp recv_all(socket, expected, acc \\ <<>>) do
    cond do
      acc == expected ->
        {:ok, acc}

      byte_size(acc) >= byte_size(expected) ->
        {:error, {:mismatch, acc}}

      true ->
        case :gen_tcp.recv(socket, 0, @recv_timeout) do
          {:ok, data} -> recv_all(socket, expected, acc <> data)
          {:error, _} = err -> err
        end
    end
  end
end
