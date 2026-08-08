defmodule Rice.Import do
  @moduledoc """
  把 core 的 MySQL 导进 rice 的 Postgres。入口是 `mix rice.import`。

  一次导入就是一个事务:dry-run 靠**回滚**实现,而不是靠"只读一遍不写" ——
  只有真的插进去过,才知道唯一约束和外键会不会炸。
  """
  alias Rice.Import.{Accounts, AdminUsers, Audit, Community, Content, Governance, Grains}
  alias Rice.Repo

  # 报告里的表顺序,也是实际的导入顺序。被依赖的排在前面 ——
  # 附件先建出来,users 紧随其后(其余每张表的外键都落在它上面),
  # 勋章发放要等勋章,投票和评论要等提案。
  @order [
    :attachments,
    :apps,
    :banners,
    :announcements,
    :site_settings,
    :admin_users,
    :users,
    :nodes,
    :badges,
    :badge_awards,
    :proposals,
    :proposal_votes,
    :proposal_comments,
    :grain_transfers
  ]

  @doc "报告里表的展示顺序,也是实际的导入顺序。"
  def order, do: @order

  # 摆明是测试库的后缀。**白名单**,不是黑名单。
  @dev_suffixes ~w(_dev _test _staging)

  @doc "白名单里的测试库后缀。"
  def dev_suffixes, do: @dev_suffixes

  @doc """
  目标库看起来是不是一个可以随便写的测试库。

  原来的判定是黑名单(URL 里含 `node.xjdao.xyz`,或含 `prod` 且不含 `localhost`)。
  **在服务器上跑的时候那条形同虚设** —— 生产和测试共用同一个 Postgres 实例,
  测试库是 `…@127.0.0.1:5432/rice_dev`,生产库是同一实例上的 `…/rice`:
  host 都是 `127.0.0.1`,`rice` 也不含 `prod`,两个条件一个都不触发。
  库名少写四个字符就能把生产库当成导入目标,而安全阀一声不吭。

  白名单反过来 —— 判断错的方向从"放过生产库"变成"多问一次测试库"。
  """
  def dev_database?(database) when is_binary(database),
    do: String.ends_with?(database, @dev_suffixes)

  def dev_database?(_), do: false

  @doc "当前 `Rice.Repo` 连的库名。`url:` 和 `database:` 两种配法都认。"
  def target_database do
    config = Rice.Repo.config()

    case config[:database] do
      db when is_binary(db) and db != "" ->
        db

      _ ->
        config[:url]
        |> to_string()
        |> URI.parse()
        |> Map.get(:path)
        |> to_string()
        |> String.trim_leading("/")
    end
  end

  @doc """
  跑一遍导入。`commit?` 为 false 时全部在一个会回滚的事务里执行 ——
  能得到真实的行数和冲突数,但什么都不留下。
  """
  def run(commit?) do
    fun = fn ->
      # 顺序即依赖:每一步都要用到前面几步建出来的 legacy_id → TSID 映射。
      report =
        Content.import_all()
        # 管理员头像要查 attachments
        |> Map.merge(AdminUsers.import_all())
        # users 的外键只有头像,但它是后面所有表的外键目标
        |> Map.merge(Accounts.import_all())
        |> Map.merge(Community.import_all())
        |> Map.merge(Governance.import_all())
        |> Map.merge(Grains.import_all())

      # 对账必须在事务**内**算 —— dry-run 会回滚,回滚之后再数就全是 0,
      # 会得出"一条都没导进去"的错误结论。
      result = %{
        report: report,
        reconciliation:
          Content.reconcile() ++
            AdminUsers.reconcile() ++
            Accounts.reconcile() ++
            Community.reconcile() ++
            Governance.reconcile() ++
            Grains.reconcile() ++
            Audit.reconcile()
      }

      unless commit?, do: Repo.rollback({:dry_run, result})
      result
    end

    case Repo.transaction(fun, timeout: :timer.minutes(30)) do
      {:ok, result} -> {:ok, result}
      {:error, {:dry_run, result}} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end
end
