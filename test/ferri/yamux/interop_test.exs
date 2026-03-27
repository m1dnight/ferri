defmodule Yamux.EchoHandler do
  use Yamux.Handler

  @impl true
  def init(_mode), do: {:ok, %{}}

  @impl true
  def new_stream(_stream_id, stream_pid, state) do
    spawn(fn -> echo_loop(stream_pid) end)
    {:ok, state}
  end

  @impl true
  def stream_data(_stream_id, _data, _stream_pid, state) do
    {:ok, state}
  end

  @impl true
  def stream_closed(_stream_id, _stream_pid, state) do
    {:ok, state}
  end

  defp echo_loop(stream) do
    case Yamux.Stream.recv(stream, 0) do
      {:ok, data} ->
        :ok = Yamux.Stream.send_data(stream, data)
        echo_loop(stream)

      {:error, :closed} ->
        :closed
    end
  end
end

defmodule Yamux.InteropTestDocker do
  use ExUnit.Case

  @moduletag :interop

  defp accept_loop(listener) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        {:ok, _session} =
          Yamux.Session.start_link(socket, :server, handler: Yamux.EchoHandler)

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
