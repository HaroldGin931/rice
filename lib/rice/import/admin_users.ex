defmodule Rice.Import.AdminUsers do
  @moduledoc """
  导入 core 的 `t_admin_user`。

  ## 为什么密码能直接搬

  rice 的 PBKDF2 参数是照着 core 的 `PasswordHashGenerator` 定的
  (HMAC-SHA256、27500 轮、64 字节输出、Base64),摘要和盐原样搬过来就能验得过,
  管理员不必因为换后端被强制改密码。**这是这张表必须导、而不能让运营重建账号
  的主要原因** —— 重建等于所有人换密码,而管理端没有自助改密的入口。

  ## 有两类行会被跳过

  跳过的行都进警告清单,不静默丢弃 —— 少一个管理员是运营会立刻撞上的事:

    * **没有手机号。** core 的登录三步里发码那步不校验密码,手机号只是其中一个
      条件;rice 的登录和找回密码**只认手机号**(见 `Rice.Admin.start_login/3`)。
      没有手机号的账号在 rice 里存得进去也登不进来,库上还有一条 CHECK 拦着
      (`admin_users_phone_check`)。
    * **`role = 0`(core 的 Unknown)。** 那是没初始化的脏值。默认成 operator
      等于凭空发一份后台权限出去,所以宁可跳过让人来裁决。

  昵称 core 没有这一列,一律留空 —— 后台列表里显示为空,运营自己补。
  """
  import Ecto.Query
  import Rice.Import.Writer, only: [insert_each: 3]

  alias Rice.Admin.AdminUser
  alias Rice.Files.Attachment
  alias Rice.Import.Source
  alias Rice.Repo

  # core 的 RoleType:0-未知、1-管理员、2-运营人员
  @roles %{1 => "admin", 2 => "operator"}

  # 只有这两个条件都满足的行才是"打算导入的",对账拿它当分母 ——
  # 否则库里只要有一个没手机号的旧账号,对账就永远是 ❌,看的人很快会学会忽略它
  @importable "deleted = 0 AND phone <> '' AND role IN (1, 2)"

  @doc "跑一遍,返回 `%{admin_users: %{inserted:, skipped:, warnings:}}`。"
  def import_all do
    rows =
      Source.query!("""
      SELECT id, email, phone, phone_region, avatar, role, special,
             secret_data, created_at, updated_at
        FROM t_admin_user
       WHERE deleted = 0
      """)

    %{admin_users: insert_each(rows, AdminUser, &build/1)}
  end

  @doc """
  一行 MySQL → 一个 changeset,或者 `{:skip, 原因}`。

  单独拿出来是为了能不连 MySQL 就测这层映射 —— 角色、密码摘要、空字符串这几处
  正是最容易错、而错了又要等到有人登不进来才发现的地方。
  """
  def build(row) do
    with {:ok, role} <- role(row["role"]),
         {:ok, phone} <- phone(row["phone"]),
         {:ok, %{hash: hash, salt: salt}} <- secret(row["secret_data"], row["id"]) do
      {:ok,
       AdminUser.import_changeset(%AdminUser{}, %{
         legacy_id: row["id"],
         email: blank_to_nil(row["email"]),
         phone: phone,
         phone_region: blank_to_nil(row["phone_region"]) || "86",
         role: role,
         superuser: truthy?(row["special"]),
         avatar_id: attachment_id(row["avatar"]),
         password_hash: hash,
         password_salt: salt,
         password_iterations: AdminUser.iterations(),
         inserted_at: row["created_at"],
         updated_at: row["updated_at"] || row["created_at"]
       })}
    end
  end

  @doc """
  两边行数是否一致。分母是**打算导入的**那些行(见 `@importable`),
  跳过的在警告里单独看。
  """
  def reconcile do
    [%{"c" => source}] =
      Source.query!("SELECT COUNT(*) AS c FROM t_admin_user WHERE #{@importable}")

    target = Repo.aggregate(from(a in AdminUser, where: is_nil(a.deleted_at)), :count)

    [%{name: "admin_users", source: source, target: target, ok?: source == target}]
  end

  # ── 逐列 ────────────────────────────────────────────────────────────────

  defp role(value) when is_integer(value) do
    case Map.fetch(@roles, value) do
      {:ok, role} -> {:ok, role}
      :error -> {:skip, "role=#{value} 不是 admin/operator,跳过(core 的 Unknown 是脏值)"}
    end
  end

  defp role(value), do: {:skip, "role 不是整数: #{inspect(value)}"}

  defp phone(value) do
    case blank_to_nil(value) do
      nil -> {:skip, "没有手机号,在 rice 里登不进来也找不回密码,跳过"}
      phone -> {:ok, phone}
    end
  end

  # core 把摘要存成一个 json 列。EF 序列化时的键名大小写取决于运行时的 JSON
  # 策略,两种都认 —— 认错了的表现是**所有管理员都登不进去**,而导入这边
  # 行数对得上、一条警告都没有,完全看不出来。
  defp secret(raw, legacy_id) do
    with {:ok, map} <- decode(raw),
         hash when is_binary(hash) <- map["Value"] || map["value"],
         salt when is_binary(salt) <- map["Salt"] || map["salt"],
         true <- hash != "" and salt != "",
         # 盐必须是合法 Base64,否则验证时 `:crypto` 抛 ArgumentError,
         # 而 `valid_password?/2` 把它 rescue 成"密码不对"——
         # 又是一个只有当事人登录时才会发现的坏行
         {:ok, _} <- Base.decode64(salt) do
      {:ok, %{hash: hash, salt: salt}}
    else
      _ -> {:skip, "#{legacy_id} 的 secret_data 解不出可用的摘要+盐,跳过"}
    end
  end

  defp decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> :error
    end
  end

  # 驱动可能已经把 json 列解成 map 了
  defp decode(map) when is_map(map), do: {:ok, map}
  defp decode(_), do: :error

  defp attachment_id(file_id) do
    case blank_to_nil(file_id) do
      nil -> nil
      id -> Repo.one(from a in Attachment, where: a.legacy_id == ^id, select: a.id)
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil

  # MySQL 的 tinyint 过来是整数,但不同驱动版本上也见过布尔
  defp truthy?(1), do: true
  defp truthy?(true), do: true
  defp truthy?(_), do: false
end
