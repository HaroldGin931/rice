defmodule Rice.Repo.Migrations.CreateUsers do
  use Ecto.Migration
  import Rice.Migration

  # 原 t_user。相对 core 的改动见 docs/backend-migration-plan.md §3.2:
  #   - email / phone 从 NOT NULL DEFAULT '' 改成可空 + partial unique index
  #     (core 上没有任何唯一索引,并发注册同一手机号会双双通过)
  #   - domain_name -> handle,node_user -> node_member,disable -> disabled_at
  #   - 去掉 created_by / updated_by / row_version
  #
  # 唯一索引一律带 `where deleted_at is null` —— 生产数据里软删用户与存活用户
  # 之间有 1 个 handle 冲突和 5 个手机号冲突(§6.4 实测),不带条件建不起来。
  def change do
    create table(:users, primary_key: false) do
      tsid_primary_key()
      add :legacy_id, :string, size: 36
      add :did, :string, size: 128, null: false
      add :handle, :string, size: 256, null: false
      add :email, :string, size: 255
      add :phone, :string, size: 32
      add :phone_region, :string, size: 8, null: false, default: "86"
      add :nickname, :string, size: 64, null: false, default: ""
      add :bio, :string, size: 512, null: false, default: ""
      add :avatar_id, tsid_references(:attachments, on_delete: :nilify_all)
      add :grain_balance, :bigint, null: false, default: 0
      add :node_member, :boolean, null: false, default: false
      add :disabled_at, :utc_datetime_usec
      add :deleted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:did], where: "deleted_at is null", name: :users_did_idx)

    create unique_index(:users, ["lower(handle)"],
             where: "deleted_at is null",
             name: :users_handle_idx
           )

    create unique_index(:users, ["lower(email)"],
             where: "deleted_at is null and email is not null",
             name: :users_email_idx
           )

    create unique_index(:users, [:phone_region, :phone],
             where: "deleted_at is null and phone is not null",
             name: :users_phone_idx
           )

    create unique_index(:users, [:legacy_id], where: "legacy_id is not null")

    create constraint(:users, :users_grain_balance_non_negative, check: "grain_balance >= 0")
  end
end
