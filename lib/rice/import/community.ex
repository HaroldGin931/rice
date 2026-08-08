defmodule Rice.Import.Community do
  @moduledoc """
  导入 `t_node` / `t_medal` / `t_user_medal`。

  三张表都只取 `deleted = 0` —— rice 这边它们没有软删列,core 那边删掉的节点和
  勋章也没有任何东西引用。这和 `users` / `proposals` 不同,后两者的软删行有
  下游引用,必须带着 `deleted_at` 导进来。
  """
  import Rice.Import.Writer

  alias Rice.Accounts.User
  alias Rice.Community.{Badge, BadgeAward, Node}
  alias Rice.Files.Attachment
  alias Rice.Import.Source
  alias Rice.Repo

  @doc "跑一遍,返回 nodes / badges / badge_awards 三段报告。"
  def import_all do
    users = legacy_map(User)
    attachments = legacy_map(Attachment)

    nodes = import_nodes(users, attachments)
    badges = import_badges(attachments)
    # 发放记录要等勋章建完才解析得到 badge_id
    awards = import_badge_awards(users, legacy_map(Badge))

    %{nodes: nodes, badges: badges, badge_awards: awards}
  end

  def reconcile do
    for {table, name, schema} <- [
          {"t_node", "nodes", Node},
          {"t_medal", "badges", Badge},
          {"t_user_medal", "badge_awards", BadgeAward}
        ] do
      source = Source.count!(table)
      target = Repo.aggregate(schema, :count)
      %{name: name, source: source, target: target, ok?: source == target}
    end
  end

  # ── 节点 ────────────────────────────────────────────────────────────────

  defp import_nodes(users, attachments) do
    rows =
      Source.query!("""
      SELECT id, user_id, logo, name, description, sort, created_at, updated_at
        FROM t_node WHERE deleted = 0
      """)

    insert_each(rows, Node, fn row ->
      # user_did 不迁 —— 那是 users.did 的副本,用户换 DID 就成脏数据
      with {:ok, user_id} <- fk(users, row["user_id"], "t_node.user_id", row["id"]) do
        {:ok,
         %Node{}
         |> Node.changeset(%{
           legacy_id: row["id"],
           user_id: user_id,
           name: row["name"],
           description: row["description"] || "",
           position: row["sort"] || 0,
           logo_id: Map.get(attachments, blank_to_nil(row["logo"]))
         })
         |> keep_timestamps(row)}
      end
    end)
  end

  # ── 勋章 ────────────────────────────────────────────────────────────────

  defp import_badges(attachments) do
    rows =
      Source.query!("""
      SELECT id, attach_id, name, created_at, updated_at
        FROM t_medal WHERE deleted = 0
      """)

    insert_each(rows, Badge, fn row ->
      # quantity 不迁 —— 那是 count(*) 的缓存,rice 现算
      {:ok,
       %Badge{}
       |> Badge.changeset(%{
         legacy_id: row["id"],
         name: row["name"],
         image_id: Map.get(attachments, blank_to_nil(row["attach_id"]))
       })
       |> keep_timestamps(row)}
    end)
  end

  defp import_badge_awards(users, badges) do
    rows =
      Source.query!("""
      SELECT id, user_id, medal_id, get_time, created_at, updated_at
        FROM t_user_medal WHERE deleted = 0
      """)

    insert_each(rows, BadgeAward, fn row ->
      # nick_name / avatar / phone / phone_region / email / attach_id / name
      # 这 7 列都是副本,一律不迁 —— 用户改个昵称它们就是脏数据
      with {:ok, user_id} <- fk(users, row["user_id"], "t_user_medal.user_id", row["id"]),
           {:ok, badge_id} <- fk(badges, row["medal_id"], "t_user_medal.medal_id", row["id"]) do
        {:ok,
         %BadgeAward{}
         |> BadgeAward.changeset(%{
           legacy_id: row["id"],
           user_id: user_id,
           badge_id: badge_id,
           awarded_at: row["get_time"] || row["created_at"]
         })
         |> keep_timestamps(row)}
      end
    end)
  end
end
