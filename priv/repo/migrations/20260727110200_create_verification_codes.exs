defmodule Rice.Repo.Migrations.CreateVerificationCodes do
  use Ecto.Migration
  import Rice.Migration

  # core 把验证码放在 Redis 里(30 分钟 TTL)。搬进 Postgres 换来三件事:
  #   1. 可按 target 限流 —— core **没有任何发码频率限制**
  #   2. 可限制尝试次数 —— core 那边 6 位码**可以无限次猜**
  #   3. 可审计
  # 过期行由 Oban 的定时任务清理。
  def change do
    create table(:verification_codes, primary_key: false) do
      tsid_primary_key()
      add :channel, :string, size: 8, null: false
      add :target, :string, size: 255, null: false
      add :purpose, :string, size: 24, null: false
      add :code_hash, :binary, null: false
      add :attempts, :integer, null: false, default: 0
      add :consumed_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:verification_codes, [:channel, :target, :purpose, :id])
    create index(:verification_codes, [:expires_at])

    create constraint(:verification_codes, :verification_codes_channel,
             check: "channel in ('sms', 'email')"
           )
  end
end
