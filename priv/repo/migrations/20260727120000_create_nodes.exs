defmodule Rice.Repo.Migrations.CreateNodes do
  use Ecto.Migration
  import Rice.Migration

  # 原 t_node。删掉 user_did —— 那是 t_user.did 的副本,用户换 DID 就成脏数据。
  def change do
    create table(:nodes, primary_key: false) do
      tsid_primary_key()
      add :legacy_id, :string, size: 36
      add :user_id, tsid_references(:users, on_delete: :nilify_all)
      add :name, :string, size: 64, null: false
      add :description, :text, null: false, default: ""
      add :logo_id, tsid_references(:attachments, on_delete: :nilify_all)
      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:nodes, [:legacy_id], where: "legacy_id is not null")
    create index(:nodes, [:position, :id])
    create index(:nodes, [:user_id])
  end
end
