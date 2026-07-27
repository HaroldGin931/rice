defmodule Mix.Tasks.Rice.Import do
  @shortdoc "把 xiangjiandao-core 的 MySQL 数据导入 rice 的 Postgres"

  @moduledoc """
  从 core 的 MySQL 导入数据。**默认是 dry-run,不写任何东西。**

      mix rice.import --source mysql://root:PASS@127.0.0.1:3306/xiangjiandao
      mix rice.import --source ... --commit

  安全阀:

    * 不加 `--commit` 时,整个导入跑在一个必定回滚的事务里 —— 能拿到真实的
      行数和冲突数,但什么都不留下。
    * 加了 `--commit` 时,会先检查目标 Postgres 是否是生产库;是的话必须再加
      `--i-know-this-is-production` 才继续。
    * 按 `legacy_id` 幂等,可以反复跑;支持"提前预导 → 切换日只跑增量"。

  期 1 覆盖:attachments(元数据)/ apps / banners / announcements / site_settings。
  文件本体的搬运、users 及其下游是后面几期的事。
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

    if commit?, do: guard_production!(opts)

    {:ok, _pid} = Rice.Import.Source.start_link(source)

    Mix.shell().info(mode_banner(commit?))
    Mix.shell().info("源:  #{redact(source)}")
    Mix.shell().info("目标:#{redact(target_url())}\n")

    case Rice.Import.Content.run(commit?) do
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

  # 生产库的判定故意保守:主机名或库名里出现这些字样就算。宁可多问一次。
  defp guard_production!(opts) do
    url = target_url()
    production? = String.contains?(url, "node.xjdao.xyz") or looks_like_prod?(url)

    if production? and not opts[:i_know_this_is_production] do
      Mix.raise("""
      目标看起来是生产库:#{redact(url)}

      按 docs/backend-migration-plan.md §7.0,生产导入需要单独确认。
      确实要写生产,请显式加上 --i-know-this-is-production。
      """)
    end
  end

  defp looks_like_prod?(url) do
    host_and_db = String.downcase(url)
    String.contains?(host_and_db, "prod") and not String.contains?(host_and_db, "localhost")
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

    for key <- [:attachments, :apps, :banners, :announcements, :site_settings] do
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
