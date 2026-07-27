defmodule Rice.Repo.Migrations.CreateAnnouncements do
  use Ecto.Migration
  import Rice.Migration

  # 原 t_information。name -> title,attach_id -> attachment_id,sort -> position。
  def change do
    create table(:announcements, primary_key: false) do
      tsid_primary_key()
      add :legacy_id, :string, size: 36
      add :title, :string, size: 128, null: false
      add :attachment_id, tsid_references(:attachments, on_delete: :nilify_all)
      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:announcements, [:legacy_id], where: "legacy_id is not null")
    create index(:announcements, [:position, :id])
  end
end
