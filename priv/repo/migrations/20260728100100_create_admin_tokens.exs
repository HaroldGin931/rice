defmodule Rice.Repo.Migrations.CreateAdminTokens do
  use Ecto.Migration
  import Rice.Migration

  # 和 api_tokens 一样是不透明令牌,但单独一张表 —— 管理端和 C 端的会话
  # 不该有任何混用的可能。一张表加个 context 列的话,写错一个 where
  # 就等于把管理员权限发给了普通用户。
  def change do
    create table(:admin_tokens, primary_key: false) do
      tsid_primary_key()
      add :admin_user_id, tsid_references(:admin_users, on_delete: :delete_all)
      add :token_hash, :binary, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :last_used_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:admin_tokens, [:token_hash])
    create index(:admin_tokens, [:admin_user_id])
    create index(:admin_tokens, [:expires_at])
  end
end
