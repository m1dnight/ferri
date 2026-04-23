defmodule Ferri.HttpListener.Connection do
  alias Ferri.HttpListener.Connection

  defstruct [:socket, buffer: <<>>]

  require Logger
  @spec start_link(:gen_tcp.socket()) :: GenServer.on_start()
  def start_link(socket) do
    GenServer.start_link(Connection, socket)
  end

  @impl true
  def init(socket) do
    state = %Connection{socket: socket}
    Logger.debug("New client process started")
    {:ok, state}
  end

  @impl true
  def handle_info({:tcp, socket, data}, %Connection{socket: socket} = state) do
    Logger.debug("New data on socket")
    state = update_in(state.buffer, &(&1 <> data))
    state = handle_new_data(state)

    {:noreply, state}
  end

  def handle_info({:tcp_closed, socket}, %Connection{socket: socket} = state) do
    Logger.debug("Client closed connection")
    :gen_tcp.close(socket)
    {:stop, :normal, state}
  end

  def handle_info({:tcp_error, socket, reason}, %Connection{socket: socket} = state) do
    Logger.error("TCP connection error: #{inspect(reason)}")
    {:stop, :normal, state}
  end

  def handle_info(m, state) do
    Logger.debug "Unhandled message: #{inspect m}"
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------#
  #                                Helpers                                     #
  # ---------------------------------------------------------------------------#

  defp handle_new_data(state) do
    case String.split(state.buffer, "\n", parts: 2) do
      [line, rest] ->
        :ok = :gen_tcp.send(state.socket, line <> "\n")
        state = put_in(state.buffer, rest)
        handle_new_data(state)

      _other ->
        state
    end
  end
end
