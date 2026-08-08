defmodule Mix.Tasks.Rice.Import do
  @shortdoc "把 xiangjiandao-core 的 MySQL 数据导入 rice 的 Postgres"

  @moduledoc """
  从 core 的 MySQL 导入数据。**默认是 dry-run,不写任何东西。**

      mix rice.import --source mysql://root:PASS@127.0.0.1:3306/xiangjiandao
      mix rice.import --source ... --commit

  安全阀:

    * 不加 `--commit` 时,整个导入跑在一个必定回滚的事务里 —— 能拿到真实的
      行数和冲突数,但什么都不留下。
    * 加了 `--commit` 时,目标库名**必须**以 `_dev` / `_test` / `_staging` 结尾,
      否则要显式加 `--i-know-this-is-production`。见下。
    * 按 `legacy_id` 幂等,可以反复跑;支持"提前预导 → 切换日只跑增量"。

  ## 目标库为什么用白名单而不是黑名单

  原来的判定是黑名单:URL 里出现 `node.xjdao.xyz`,或者含 `prod` 且不含
  `localhost`。**在服务器上跑的时候这条形同虚设** —— 生产和测试共用同一个
  Postgres 实例,测试库是 `…@127.0.0.1:5432/rice_dev`,生产库是同一实例上的
  `…/rice`。两者 host 都是 `127.0.0.1`,`rice` 也不含 `prod`,黑名单一个都不触发。
  库名少写四个字符就能把生产库当成导入目标,而安全阀一声不吭。

  白名单反过来:默认**只认摆明是测试库的名字**,其余一律拦下来。判断错的方向
  从"放过生产库"变成"多问一次测试库",这是这两种错误里代价小的那个。

  ## 覆盖范围

  core 的 14 张表全部覆盖(有几张是合并进来的,见下)。导入顺序即依赖顺序:

      attachments ← apps / banners / announcements / site_settings / admin_users
                  ← users ← nodes / badges ← badge_awards
                          ← proposals ← proposal_votes / proposal_comments
                          ← grain_transfers

  几处不是一对一的:

    * `t_point_record` + `t_point_distribute_record` → `grain_transfers` 一张。
      每笔转账 core 写两行(收付各一),这里折成一行;后者是前者 `type=3` 的
      完整副本,只用来对账不作为数据源。
    * `t_user` / `t_proposal` / `t_proposal_comment` **连软删的行一起导**
      (带 `deleted_at`)—— 它们的软删行有下游引用。其余表只取 `deleted = 0`。
    * core 没有附件表,fileId 从七张表的列里收集去重。

  文件本体的搬运是另一个任务:`mix rice.backfill_attachments`。
  """
  use Mix.Task

  @requirements ["app.start"]

  @switches [
    source: :string,
    commit: :boolean,
    i_know_this_is_production: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)

    # Ecto 默认把每条 SQL 都打到 debug,几千行数据会把报告冲掉
    Logger.configure(level: :info)

    source = opts[:source] || Mix.raise("必须提供 --source mysql://user:pass@host:port/db")
    commit? = opts[:commit] || false

    if commit?, do: guard_target!(opts)

    {:ok, _pid} = Rice.Import.Source.start_link(source)

    Mix.shell().info(mode_banner(commit?))
    Mix.shell().info("源:  #{redact(source)}")
    Mix.shell().info("目标:#{redact(target_url())}\n")

    case Rice.Import.run(commit?) do
      {:ok, %{report: report, reconciliation: reconciliation}} ->
        print_report(report)
        print_reconciliation(reconciliation)
        unless commit?, do: Mix.shell().info("\n[dry-run] 事务已回滚,数据库未改动。")

      {:error, reason} ->
        Mix.raise("导入失败:#{inspect(reason)}")
    end
  end

  defp mode_banner(true), do: "== 导入(--commit,会写入)=="
  defp mode_banner(false), do: "== 导入(dry-run,不写入)=="

  defp guard_target!(opts) do
    database = Rice.Import.target_database()

    cond do
      Rice.Import.dev_database?(database) ->
        :ok

      opts[:i_know_this_is_production] ->
        Mix.shell().info("⚠️  目标库 `#{database}` 不是测试库,已被 --i-know-this-is-production 放行。\n")

      true ->
        Mix.raise("""
        目标库是 `#{database}`,不在测试库白名单里(要以 #{Enum.join(Rice.Import.dev_suffixes(), " / ")} 结尾)。

        目标:#{redact(target_url())}

        生产和测试共用同一个 Postgres 实例,`rice` 和 `rice_dev` 只差四个字符 ——
        所以这里不猜,只认摆明是测试库的名字。

        按 docs/backend-migration-plan.md §7.0,写非测试库需要单独确认。
        确实要写,请显式加上 --i-know-this-is-production。
        """)
    end
  end

  defp target_url do
    config = Rice.Repo.config()
    config[:url] || "#{config[:hostname]}/#{config[:database]}"
  end

  defp redact(url), do: String.replace(url, ~r{://([^:/@]+):[^@]*@}, "://\\1:***@")

  defp print_report(report) do
    Mix.shell().info(
      String.pad_trailing("表", 20) <> String.pad_leading("新增", 8) <> String.pad_leading("已存在", 10)
    )

    for key <- Rice.Import.order() do
      %{inserted: inserted, skipped: skipped} = report[key]

      Mix.shell().info(
        String.pad_trailing(to_string(key), 20) <>
          String.pad_leading(to_string(inserted), 8) <> String.pad_leading(to_string(skipped), 10)
      )
    end

    warnings = report |> Map.values() |> Enum.flat_map(& &1.warnings)

    if warnings != [] do
      Mix.shell().info("\n警告(#{length(warnings)} 条):")
      for w <- Enum.take(warnings, 20), do: Mix.shell().info("  - #{w}")
      if length(warnings) > 20, do: Mix.shell().info("  ... 还有 #{length(warnings) - 20} 条")
    end
  end

  defp print_reconciliation(reconciliation) do
    Mix.shell().info("\n对账(MySQL deleted=0  vs  Postgres,在事务内统计):")

    for %{name: name, source: source, target: target, ok?: ok?} <- reconciliation do
      mark = if ok?, do: "✅", else: "❌"
      Mix.shell().info("  #{mark} #{String.pad_trailing(name, 16)} #{source} -> #{target}")
    end
  end
end
