defmodule Mix.Tasks.Rice.BackfillAttachments do
  @shortdoc "把 core 磁盘上的文件搬进 rice 的存储"

  @moduledoc """
  回填附件字节。**默认是 dry-run,不写任何东西。**

      mix rice.backfill_attachments --source-dir /path/to/core/Data
      mix rice.backfill_attachments --source-dir ... --commit

  `--source-dir` 指向 core 的 Data 目录(里面有 `Picture/` 和 `File/`)。
  生产上是 `/opt/xjdao/data/core`。

  幂等:只处理 `storage_key` 还是 NULL 的行,重复跑不会重复搬。
  """
  use Mix.Task

  @requirements ["app.start"]

  @switches [source_dir: :string, commit: :boolean]

  @impl Mix.Task
  def run(argv) do
    Logger.configure(level: :info)
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)

    source_dir = opts[:source_dir] || Mix.raise("必须提供 --source-dir(core 的 Data 目录)")
    commit? = opts[:commit] || false

    unless File.dir?(source_dir), do: Mix.raise("目录不存在:#{source_dir}")

    pending = Rice.Files.list_unstored()

    Mix.shell().info(if commit?, do: "== 回填(--commit,会写入)==", else: "== 回填(dry-run)==")
    Mix.shell().info("源:  #{source_dir}")
    Mix.shell().info("目标:#{Rice.Files.Storage.Local.root()}")
    Mix.shell().info("待处理:#{length(pending)} 个附件\n")

    result = Rice.Import.Attachments.run(source_dir, commit?)

    Mix.shell().info("已复制: #{result.copied}  (#{mb(result.bytes)} MB)")
    Mix.shell().info("源文件缺失: #{length(result.missing)}")
    Mix.shell().info("失败: #{length(result.failed)}")

    for legacy <- Enum.take(result.missing, 20), do: Mix.shell().info("  缺失: #{legacy}")

    for {id, reason} <- Enum.take(result.failed, 20),
        do: Mix.shell().info("  失败: #{id} #{reason}")

    unless commit?, do: Mix.shell().info("\n[dry-run] 未写入任何内容。")

    if result.failed != [], do: Mix.raise("有 #{length(result.failed)} 个文件回填失败")
  end

  defp mb(bytes), do: Float.round(bytes / 1024 / 1024, 1)
end
