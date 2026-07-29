defmodule Rice.Repo.Migrations.RequireAdminPhone do
  use Ecto.Migration

  # 原来的约束是"邮箱或手机号至少有一个",但登录和找回密码都只走手机号 ——
  # 只填邮箱的账号存得进去,却登不进来也找不回密码。
  # 约束收紧成手机号必填,免得 `mix rice.import` 之类绕过 changeset 的路径
  # 再把这种账号写进来。
  def up do
    drop constraint(:admin_users, :admin_users_contact_check)

    create constraint(:admin_users, :admin_users_phone_check, check: "phone is not null")
  end

  def down do
    drop constraint(:admin_users, :admin_users_phone_check)

    create constraint(:admin_users, :admin_users_contact_check,
             check: "email is not null or phone is not null"
           )
  end
end
