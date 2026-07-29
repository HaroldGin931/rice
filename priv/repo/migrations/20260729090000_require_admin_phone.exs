defmodule Rice.Repo.Migrations.RequireAdminPhone do
  use Ecto.Migration

  import Ecto.Query

  # 原来的约束是"邮箱或手机号至少有一个",但登录和找回密码都只走手机号 ——
  # 只填邮箱的账号存得进去,却登不进来也找不回密码。
  # 约束收紧成手机号必填,免得 `mix rice.import` 之类绕过 changeset 的路径
  # 再把这种账号写进来。
  #
  # ## 已经在库里的那些怎么办
  #
  # 旧约束允许只填邮箱,所以库里**可能已经有**这种行。直接 `CREATE CONSTRAINT`
  # 会因为现存行不满足而报错,而这时旧约束已经被 drop 掉了 —— 迁移中途失败,
  # 库停在一个两边都不是的状态上。
  #
  # 所以先把这种账号软删掉再加约束。它们本来就登不进去:没有手机号就换不到
  # 验证码,而验证码是登录和找回密码的唯一入口。软删而不是硬删,是因为
  # 审计要指得到,而且部分唯一索引带着 `deleted_at is null`,软删的行不占用邮箱。
  #
  # 顺带撤掉它们的令牌 —— 这种账号理论上不该有令牌,但如果有,那更得撤。
  def up do
    now = DateTime.utc_now()

    {count, _} =
      repo().update_all(
        from(a in "admin_users", where: is_nil(a.phone) and is_nil(a.deleted_at)),
        set: [deleted_at: now, updated_at: now]
      )

    if count > 0 do
      repo().delete_all(
        from(t in "admin_tokens",
          join: a in "admin_users",
          on: a.id == t.admin_user_id,
          where: not is_nil(a.deleted_at) and is_nil(a.phone)
        )
      )

      # 迁移不该悄悄改数据 —— 部署日志里要留下改了几行
      IO.puts("[迁移] 软删了 #{count} 个没有手机号的管理员(它们本来就登不进去)")
    end

    drop constraint(:admin_users, :admin_users_contact_check)

    # 约束说的是"**活着的**管理员必须有手机号"。软删的行豁免 ——
    # 否则上面刚软删掉的那些遗留账号照样会让这条约束建不起来,
    # 因为 CHECK 是对所有行生效的,不分死活。
    create constraint(:admin_users, :admin_users_phone_check,
             check: "phone is not null or deleted_at is not null"
           )
  end

  # 回滚只还原约束。上面软删掉的账号不自动恢复:分不清哪些是这次删的、
  # 哪些本来就是删掉的,猜错了等于凭空恢复一个管理员账号。
  def down do
    drop constraint(:admin_users, :admin_users_phone_check)

    create constraint(:admin_users, :admin_users_contact_check,
             check: "email is not null or phone is not null"
           )
  end
end
