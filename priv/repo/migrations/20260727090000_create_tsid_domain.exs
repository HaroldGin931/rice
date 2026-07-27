defmodule Rice.Repo.Migrations.CreateTsidDomain do
  use Ecto.Migration

  # 所有业务表的主键/外键类型。见 Rice.Tsid 和 Rice.Migration。
  # 13 个字符的 base32,字典序即时间序。

  def up do
    execute("CREATE DOMAIN tsid AS varchar(13)")
  end

  def down do
    execute("DROP DOMAIN tsid")
  end
end
