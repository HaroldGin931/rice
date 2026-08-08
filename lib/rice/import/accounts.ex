defmodule Rice.Import.Accounts do
  @moduledoc """
  导入 core 的 `t_user`。

  这是整个导入的基石 —— 节点、勋章、提案、投票、评论、稻米流水的外键全部落在
  这张表上,所以它必须排在最前面(附件之后)。

  ## 软删的用户也导

  其余几张表只取 `deleted = 0`,这张不是。生产实测(§6.4⑤)里 7 个软删用户与
  存活用户之间有 1 个 handle 冲突和 5 个手机号冲突;唯一索引带着
  `where deleted_at is null` 正是为此准备的。不导的话,引用他们的流水和评论
  会变成解析不到的外键 —— 而外键解析失败是硬错误。

  ## 密码不在这里

  rice 不存 C 端密码,PDS 才是权威。所以这张表导完,用户能不能登录取决于
  **rice 连的是哪个 PDS**:测试环境连 dev PDS,而生产用户的账号在生产 PDS 上,
  导进来的用户在测试环境是登不进去的。这不是导入的缺陷,是 §6.5 那条
  "PDS 仍是密码权威"的直接后果。
  """
  import Rice.Import.Writer

  alias Rice.Accounts.User
  alias Rice.Files.Attachment
  alias Rice.Import.Source
  alias Rice.Repo

  @doc "跑一遍,返回 `%{users: %{inserted:, skipped:, warnings:}}`。"
  def import_all do
    avatars = legacy_map(Attachment)

    rows =
      Source.query!("""
      SELECT id, email, phone, phone_region, avatar, nick_name, introduction,
             domain_name, did, score, node_user, `disable`, deleted,
             created_at, updated_at
        FROM t_user
      """)

    %{users: insert_each(rows, User, &build(&1, avatars))}
  end

  @doc """
  一行 `t_user` → 一个 changeset,或 `{:skip, 原因}`。

  独立出来是为了能不连 MySQL 就测这层映射。
  """
  def build(row, avatars \\ %{}) do
    with {:ok, did} <- required(row["did"], "did"),
         {:ok, handle} <- required(row["domain_name"], "domain_name(handle)") do
      {:ok,
       User.import_changeset(%User{}, %{
         legacy_id: row["id"],
         did: did,
         handle: handle,
         email: blank_to_nil(row["email"]),
         phone: blank_to_nil(row["phone"]),
         phone_region: blank_to_nil(row["phone_region"]) || "86",
         nickname: row["nick_name"] || "",
         bio: row["introduction"] || "",
         # core 的 avatar 列存过两种东西:老的 fileId,和 PDS 的 blob URL。
         # 只有前者在 rice 里有对应的附件行,后者解析不出来就是没有头像。
         avatar_id: attachment_id(avatars, row["avatar"]),
         grain_balance: row["score"] || 0,
         node_member: truthy?(row["node_user"]),
         disabled_at: if(truthy?(row["disable"]), do: row["updated_at"]),
         deleted_at: deleted_at(row),
         inserted_at: row["created_at"],
         updated_at: row["updated_at"] || row["created_at"]
       })}
    end
  end

  @doc """
  对账。分母是 MySQL 的**全部**行(包括软删)—— 这张表软删也要导。
  """
  def reconcile do
    [%{"c" => source}] = Source.query!("SELECT COUNT(*) AS c FROM t_user")
    target = Repo.aggregate(User, :count)

    [%{name: "users(含软删)", source: source, target: target, ok?: source == target}]
  end

  # ── 逐列 ────────────────────────────────────────────────────────────────

  defp required(value, name) do
    case blank_to_nil(value) do
      nil -> {:skip, "#{name} 为空,建不出用户,跳过"}
      trimmed -> {:ok, trimmed}
    end
  end

  defp attachment_id(avatars, value) do
    case blank_to_nil(value) do
      nil -> nil
      file_id -> Map.get(avatars, file_id)
    end
  end
end
