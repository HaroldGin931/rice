defmodule Rice.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    # 主键生成器的进程状态(atomics + 随机 clock_id)。必须在任何 Repo 写入之前。
    Rice.Tsid.init()

    children = [
      RiceWeb.Telemetry,
      Rice.Repo,
      {DNSCluster, query: Application.get_env(:rice, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Rice.PubSub},
      # 后台任务。生产上由 OBAN_ENABLED 控制,未开启时 queues/plugins 均为 false,
      # 进程照常启动但不访问数据库。见 config/runtime.exs。
      {Oban, Application.fetch_env!(:rice, Oban)},
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

  # DAO backend connection (MySQL t_user) — only started when configured
  # (DAO_MYSQL_PASSWORD set); dev without the DAO stack runs fine.
  #
  # 2026-08-21：去掉了 Redix。签名用的 JWKS 改从配置读（见 `Rice.Dao` 的
  # 模块文档），**rice 不再连 Redis**。
  defp dao_children do
    cfg = Application.get_env(:rice, :dao, [])

    if cfg[:mysql_password] not in [nil, ""] do
      # 配置齐不齐现在启动就能知道，不必等到某个用户登录时才在日志里冒一行
      # warning ——「错误报在没人看的地方」是这套系统反复踩的坑。
      # 但**不 raise**：daoJwt 已经没有消费者，不该让它把整个应用拖崩。
      case Rice.Dao.current_jwk() do
        {:ok, %{"Kid" => kid}} ->
          Logger.info("dao: JWKS 已加载，kid=#{kid}")

        other ->
          Logger.error(
            "dao: DAO_MYSQL_PASSWORD 已配置但 JWKS 不可用（#{inspect(other)}）—— " <>
              "Semi 登录仍可用，但不会签发 daoJwt。检查 secret/xjdao 的 dao_jwks。"
          )
      end

      [
        {MyXQL,
         name: Rice.DaoSql,
         hostname: cfg[:mysql_host],
         port: cfg[:mysql_port],
         username: cfg[:mysql_user],
         password: cfg[:mysql_password],
         database: cfg[:mysql_database],
         pool_size: 2}
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
