defmodule Rice.Repo.Migrations.CreateApiTokens do
  use Ecto.Migration
  import Rice.Migration

  # 替换 core 的 daoJwt。core 把 RS256 私钥放在 Redis `netcorepal:jwtsettings`,
  # rice 从同一个 key 读出来自己签 —— 迁完这条耦合就没了。
  #
  # 换成库内不透明 token 的实际收益:**可撤销**。现在禁用一个用户,他手上的
  # JWT 还能用满 30 天;删掉 token 行则立即失效。
  #
  # 只存 sha256,明文仅在签发时返回一次 —— 库被读走也换不到有效凭据。
  def change do
    create table(:api_tokens, primary_key: false) do
      tsid_primary_key()
      add :user_id, tsid_references(:users, on_delete: :delete_all)
      add :token_hash, :binary, null: false
      add :context, :string, size: 16, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :last_used_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:api_tokens, [:token_hash])
    create index(:api_tokens, [:user_id])
    create index(:api_tokens, [:expires_at])
  end
end
