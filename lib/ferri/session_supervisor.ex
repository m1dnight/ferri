defmodule Ferri.SessionSupervisor do
  @moduledoc """
  Supervises the two tunnel-facing listeners:

  * `Ferri.Tunnel.Listener` — accepts ferri client connections on the TCP port.
  * `Ferri.Tunnel.HttpListener` — accepts visitor HTTP traffic.

  Uses `:one_for_one`, so a crash in one listener restarts only that listener
  without bouncing the other one (or anything above this supervisor).
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    tcp_port = Keyword.fetch!(opts, :tcp_port)
    http_port = Keyword.fetch!(opts, :http_port)

    children = [
      {Ferri.Tunnel.Listener, port: tcp_port},
      {Ferri.Tunnel.HttpListener, port: http_port}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
