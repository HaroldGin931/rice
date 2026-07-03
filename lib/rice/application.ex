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

    children = children ++ dao_children()

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Rice.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # DAO backend connections (MySQL t_user + Redis JWKS) — only started when
  # configured (DAO_MYSQL_PASSWORD set); dev without the DAO stack runs fine.
  defp dao_children do
    cfg = Application.get_env(:rice, :dao, [])

    if cfg[:mysql_password] not in [nil, ""] do
      [
        {MyXQL,
         name: Rice.DaoSql,
         hostname: cfg[:mysql_host],
         port: cfg[:mysql_port],
         username: cfg[:mysql_user],
         password: cfg[:mysql_password],
         database: cfg[:mysql_database],
         pool_size: 2},
        {Redix,
         name: Rice.DaoRedis,
         host: cfg[:redis_host],
         port: cfg[:redis_port],
         password: cfg[:redis_password],
         database: cfg[:redis_database]}
      ]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    RiceWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
