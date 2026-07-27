defmodule Rice.Repo.Migrations.CreateBanners do
  use Ecto.Migration
  import Rice.Migration

  # 原 t_banner。banner_file_id -> image_id,link_address -> url,sort -> position。
  def change do
    create table(:banners, primary_key: false) do
      tsid_primary_key()
      add :legacy_id, :string, size: 36
      add :image_id, tsid_references(:attachments, on_delete: :nilify_all)
      add :url, :string, size: 512, null: false, default: ""
      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:banners, [:legacy_id], where: "legacy_id is not null")
    create index(:banners, [:position, :id])
  end
end
