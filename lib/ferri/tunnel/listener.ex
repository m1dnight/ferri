defmodule Ferri.Tunnel.Listener do
  @moduledoc """
  TCP listener that accepts Rust client connections and establishes yamux
  sessions with the tunnel handler.
  """

  use GenServer

  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    port = Keyword.fetch!(opts, :port)

    {:ok, listener} =
      :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true])

    Logger.info("Tunnel listener started on port #{port}")

    {:ok, %{listener: listener}, {:continue, :accept}}
  end

  @impl true
  def handle_continue(:accept, state) do
    case :gen_tcp.accept(state.listener) do
      {:ok, socket} ->
        Logger.info("New tunnel client connected")

        {:ok, _session} =
          Yamux.Session.start_link(socket, :server, handler: Ferri.Tunnel.Handler)

        {:noreply, state, {:continue, :accept}}

      {:error, :closed} ->
        Logger.info("Tunnel listener closed")
        {:stop, :normal, state}
    end
  end
end
