defmodule Rice.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      RiceWeb.Telemetry,
      Rice.Repo,
      {DNSCluster, query: Application.get_env(:rice, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Rice.PubSub},
      # One-time session-handoff ticket store (Semi → social-app login).
      Rice.Handoff,
      # Start to serve requests, typically the last entry
      RiceWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Rice.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    RiceWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
