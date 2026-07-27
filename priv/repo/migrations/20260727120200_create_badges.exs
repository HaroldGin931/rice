defmodule Rice.Repo.Migrations.CreateBadges do
  use Ecto.Migration
  import Rice.Migration

  # 原 t_medal / t_user_medal。t_user_medal 上有 5 列用户信息的副本
  # (nick_name/avatar/phone/phone_region/email),一律删掉走 join。
  # quantity 也删了 —— 那是 count(*) 的缓存,会不一致。
  def change do
    create table(:badges, primary_key: false) do
      tsid_primary_key()
      add :legacy_id, :string, size: 36
      add :name, :string, size: 64, null: false
      add :image_id, tsid_references(:attachments, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:badges, [:legacy_id], where: "legacy_id is not null")

    create table(:badge_awards, primary_key: false) do
      tsid_primary_key()
      add :legacy_id, :string, size: 36
      add :badge_id, tsid_references(:badges, on_delete: :delete_all), null: false
      add :user_id, tsid_references(:users, on_delete: :delete_all), null: false
      add :awarded_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:badge_awards, [:legacy_id], where: "legacy_id is not null")
    # 同一枚勋章不能发给同一个人两次 —— core 没有这个约束
    create unique_index(:badge_awards, [:badge_id, :user_id])
    create index(:badge_awards, [:user_id, :id])
  end
end
