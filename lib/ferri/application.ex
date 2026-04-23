defmodule Ferri.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      FerriWeb.Telemetry,
      Ferri.Repo,
      {DNSCluster, query: Application.get_env(:ferri, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Ferri.PubSub},
      Ferri.Tunnel.Registry,
      {Ferri.Tunnel.Listener, port: Application.get_env(:ferri, :tcp_port)},
      {Ferri.Tunnel.HttpListener, port: Application.get_env(:ferri, :http_port)},
      # Start to serve requests, typically the last entry
      FerriWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Ferri.Supervisor]
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
