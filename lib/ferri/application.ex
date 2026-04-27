defmodule Ferri.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Ferri.Statistics.init()

    children = [
      Ferri.Tunnel.Registry,
      FerriWeb.Telemetry,
      # Ferri.Repo,
      {DNSCluster, query: Application.get_env(:ferri, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Ferri.PubSub},
      # one_for_one supervisor for the two tunnel listeners — a crash in one
      # listener won't take the other down.
      {Ferri.SessionSupervisor,
       tcp_port: Application.get_env(:ferri, :tcp_port),
       http_port: Application.get_env(:ferri, :http_port)},
      # Start to serve requests, typically the last entry
      FerriWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :rest_for_one, name: Ferri.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    FerriWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
