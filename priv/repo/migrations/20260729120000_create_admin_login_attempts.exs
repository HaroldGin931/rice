defmodule Rice.Repo.Migrations.CreateAdminLoginAttempts do
  use Ecto.Migration

  # 管理端登录第一步的密码试错计数。
  #
  # `POST /session/challenge` 密码对了返回 202、错了返回 401 —— 这正好是一个
  # 可以无限次问的"这个密码对不对"。验证码那边有 5 次上限,密码这边一次都没数。
  #
  # 计数键是**手机号**,不是管理员 id。按 id 记的话,不存在的手机号就永远不会被
  # 锁 —— 攻击者试一次就知道这个号是不是管理员,而整套设计恰恰是不想让人知道
  # 这件事(密码错和账号不存在返回的是同一个响应)。
  def change do
    create table(:admin_login_attempts, primary_key: false) do
      add :phone_region, :string, size: 8, null: false
      add :phone, :string, size: 20, null: false
      add :attempts, :integer, null: false, default: 0
      add :locked_until, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:admin_login_attempts, [:phone_region, :phone])
  end
end
