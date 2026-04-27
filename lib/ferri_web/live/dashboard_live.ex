defmodule FerriWeb.DashboardLive do
  use FerriWeb, :live_view

  alias Ferri.Statistics

  @tick_ms 1000
  @history_size 60

  @impl true
  def mount(_params, _session, socket) do
    _ = if connected?(socket), do: :timer.send_interval(@tick_ms, :tick)

    # Read the initial snapshot
    snapshot = Statistics.snapshot()

    {:ok,
     assign(socket,
       page_title: "Dashboard — Ferri",
       sessions: snapshot.sessions,
       up_bps: snapshot.down,
       down_bps: snapshot.up,
       total_up: snapshot.up,
       total_down: snapshot.down,
       history: [],
       prev: snapshot
     )}
  end

  @impl true
  def handle_info(:tick, socket) do
    now = Statistics.snapshot()
    prev = socket.assigns.prev

    up = now.up - prev.up
    down = now.down - prev.down

    history =
      [{System.system_time(:second), up, down} | socket.assigns.history]
      |> Enum.take(@history_size)

    {:noreply,
     assign(socket,
       sessions: now.sessions,
       up_bps: up,
       down_bps: down,
       total_up: now.up,
       total_down: now.down,
       history: history,
       prev: now
     )}
  end

  @doc false
  @spec format_rate(non_neg_integer()) :: String.t()
  def format_rate(bps), do: format_bytes(bps) <> "/s"

  @spec format_bytes(non_neg_integer()) :: String.t()
  def format_bytes(n) when n < 1_000, do: "#{n} B"

  def format_bytes(n) when n < 1_000_000,
    do: :io_lib.format("~.1f KB", [n / 1_000]) |> to_string()

  def format_bytes(n) when n < 1_000_000_000,
    do: :io_lib.format("~.1f MB", [n / 1_000_000]) |> to_string()

  def format_bytes(n), do: :io_lib.format("~.2f GB", [n / 1_000_000_000]) |> to_string()
end
