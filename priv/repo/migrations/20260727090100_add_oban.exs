defmodule Rice.Repo.Migrations.AddOban do
  use Ecto.Migration

  # 不写死版本号:Oban 会校验"已迁移版本 >= 当前依赖要求的版本",
  # 写死了升 oban 依赖就会启动失败(2.23 要求 v14)。
  def up, do: Oban.Migration.up()

  # 只回滚到 v1,保留 oban_jobs 表本身,避免误删还没跑完的任务
  def down, do: Oban.Migration.down(version: 1)
end
