defmodule Ferri.Tunnel.HttpListener do
  @moduledoc """
  HTTP listener.

  The HTTP listener listens for external calls to a ferri subdomain and routes
  them to the appropriate Yamux session if it exists.
  """

  use GenServer

  alias Ferri.HttpListener.Connection

  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    port = Keyword.fetch!(opts, :port)

    # start the socket to listen for incoming web requests
    opts = [:binary, active: false, reuseaddr: true, exit_on_close: false]

    # if the socket fails to open, abort.
    case :gen_tcp.listen(port, opts) do
      {:ok, listen_socket} ->
        Logger.info("HTTP listener started on port #{port}")
        send(self(), :accept)
        {:ok, listen_socket}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(:accept, listen_socket) do
    case :gen_tcp.accept(listen_socket, 2_000) do
      {:ok, socket} ->
        # grab some extra information from the socket for logging
        {:ok, {ip, port}} = :inet.peername(socket)
        Logger.info("Client connected #{inspect(ip)}:#{inspect(port)}")

        # Start a connection process for this client's connection.
        {:ok, pid} = Connection.start_link(socket)

        # Set the process as the socket owner, and then set it active once.
        :ok = :gen_tcp.controlling_process(socket, pid)
        :ok = :inet.setopts(socket, active: :once)

        # Accept next connection.
        send(self(), :accept)
        {:noreply, listen_socket}

      {:error, :timeout} ->
        send(self(), :accept)
        {:noreply, listen_socket}

      # todo: gracefully handle this case with the child Connection
      # processes.
      {:error, reason} ->
        {:stop, reason, listen_socket}
    end
  end
end
