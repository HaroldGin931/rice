defmodule Rice.Repo.Migrations.CreateApps do
  use Ecto.Migration
  import Rice.Migration

  # 原 t_app。`desc` 改名 `description`(desc 在 SQL 里是保留字附近的坏名),
  # `link` 改名 `url`。
  def change do
    create table(:apps, primary_key: false) do
      tsid_primary_key()
      add :legacy_id, :string, size: 36
      add :name, :string, size: 256, null: false
      add :description, :string, size: 256, null: false, default: ""
      add :url, :string, size: 512, null: false, default: ""
      add :logo_id, tsid_references(:attachments, on_delete: :nilify_all)
      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:apps, [:legacy_id], where: "legacy_id is not null")
    create index(:apps, [:position, :id])
  end
end
