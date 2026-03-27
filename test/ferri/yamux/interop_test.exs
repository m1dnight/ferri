defmodule Yamux.InteropTestDocker do
  use ExUnit.Case

  @moduletag :interop
  # loops on a single stream for incoming data and echo's it back.
  defp stream_receive_loop(stream) do
    spawn(fn ->
      case Yamux.Stream.recv(stream, 0) do
        {:ok, data} ->
          :ok = Yamux.Stream.send_data(stream, data)
          stream_receive_loop(stream)

        {:error, :closed} ->
          :closed
      end
    end)
  end

  # loops on the socket to accept incoming connections (i.e., sessions)
  defp accept_loop(listener) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        {:ok, _session} =
          Yamux.Session.start_link(socket, :server, on_stream: &stream_receive_loop/1)

        accept_loop(listener)

      {:error, :closed} ->
        :ok
    end
  end

  test "Run test suite with Docker" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)

    Task.async(fn -> accept_loop(listener) end)

    # run the go client container
    {output, exit_code} =
      System.cmd("docker", [
        "run",
        "--rm",
        "--network",
        "host",
        "-e",
        "YAMUX_HOST=localhost",
        "yamux-interop",
        "#{port}"
      ])

    # Make sure the container exited cleanly
    assert exit_code == 0

    # the output of the container is json, so parse it here to check the results
    output = JSON.decode!(output)
    assert output["failed"] == 0
    assert output["passed"] == 17

    # cleanup
    :gen_tcp.close(listener)
  end
end
