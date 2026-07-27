defmodule Rice.Repo.Migrations.CreateSiteSettings do
  use Ecto.Migration
  import Rice.Migration

  # 原 t_global_config,单行表。core 用一张普通表 + 应用层"取第一行"来表达单例,
  # 这里用一个恒真表达式上的唯一索引把单例约束交给数据库。
  #
  # foundation_public_document 原本是一个 json 数组(裸 fileId 字符串),
  # 改成 site_setting_documents 关联表,顺序显式,并且能挂 attachments 外键。
  def change do
    create table(:site_settings, primary_key: false) do
      tsid_primary_key()
      add :fund_scale, :bigint, null: false, default: 0
      add :issued_grain_scale, :bigint, null: false, default: 0
      add :proposal_approval_votes, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:site_settings, ["(true)"], name: :site_settings_singleton)

    create table(:site_setting_documents, primary_key: false) do
      tsid_primary_key()
      add :site_setting_id, tsid_references(:site_settings, on_delete: :delete_all), null: false
      add :attachment_id, tsid_references(:attachments, on_delete: :delete_all), null: false
      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create index(:site_setting_documents, [:site_setting_id, :position])
    create unique_index(:site_setting_documents, [:site_setting_id, :attachment_id])
  end
end
