defmodule Rice.Repo.Migrations.CreateAdminUsers do
  use Ecto.Migration
  import Rice.Migration

  # 管理端的身份,和 C 端的 users 完全分开 —— core 也是两张表。
  # 管理员没有 DID,不在 PDS 上,密码由 rice 自己保管。
  def change do
    create table(:admin_users, primary_key: false) do
      tsid_primary_key()
      add :legacy_id, :string, size: 36
      add :email, :string, size: 255
      add :phone, :string, size: 20
      add :phone_region, :string, size: 8, null: false, default: "86"
      add :nickname, :string, size: 64, null: false, default: ""
      add :avatar_id, tsid_references(:attachments, on_delete: :nilify_all)
      # admin | operator。core 还有个 Unknown=0,那是没初始化的脏值,不迁。
      add :role, :string, size: 16, null: false, default: "operator"
      # core 的 Special:超管不可删、不可降权
      add :superuser, :boolean, null: false, default: false
      add :password_hash, :string, size: 128, null: false
      add :password_salt, :string, size: 64, null: false
      # PBKDF2 迭代次数存在行上 —— 以后调高不用一次性重算所有人的
      add :password_iterations, :integer, null: false, default: 27_500
      add :deleted_at, :utc_datetime_usec
      add :disabled_at, :utc_datetime_usec
      add :last_login_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:admin_users, [:legacy_id])
    # 部分唯一索引:软删的行留在库里(审计要指得到),但不占用邮箱/手机号
    create unique_index(:admin_users, ["lower(email)"],
             where: "deleted_at is null and email is not null",
             name: :admin_users_email_index
           )

    create unique_index(:admin_users, [:phone_region, :phone],
             where: "deleted_at is null and phone is not null",
             name: :admin_users_phone_index
           )

    create constraint(:admin_users, :admin_users_role_check,
             check: "role in ('admin', 'operator')"
           )

    # 至少得有一种登录方式
    create constraint(:admin_users, :admin_users_contact_check,
             check: "email is not null or phone is not null"
           )
  end
end
