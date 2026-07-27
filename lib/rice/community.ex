defmodule Rice.Community do
  @moduledoc "节点与勋章。"
  import Ecto.Query

  alias Rice.Community.{Badge, BadgeAward, Node}
  alias Rice.{Pagination, Repo}

  # ── 节点 ────────────────────────────────────────────────────────────────

  @doc """
  节点列表。响应里的 `score` 是节点主的稻米余额 —— 这也是节点这块
  不能放在期 1(只读内容)的原因:它本质上是一个对 users 的 join。
  """
  def list_nodes do
    Repo.all(
      from n in Node,
        order_by: [asc: n.position, asc: n.id],
        preload: [:logo, user: :avatar]
    )
  end

  @doc "节点用户列表(原 /user/node-user-list)。"
  def list_node_members do
    Repo.all(
      from u in Rice.Accounts.User,
        where: u.node_member == true and is_nil(u.deleted_at) and is_nil(u.disabled_at),
        order_by: [asc: u.id],
        preload: [:avatar]
    )
  end

  # ── 勋章 ────────────────────────────────────────────────────────────────

  @doc "某人获得的勋章。"
  def list_badge_awards(user, params \\ %{}) do
    from(a in BadgeAward,
      where: a.user_id == ^user.id,
      preload: [badge: :image]
    )
    |> Pagination.paginate(Repo, Pagination.params(params))
  end

  @doc """
  勋章全集,附上**指定用户**的获得时间(没获得就是 nil)。勋章墙要把没拿到的
  也灰着显示出来 —— core 是让 `/user-medal/page` 同时返回已获得和未获得,
  再靠 `getTime` 是不是 null 区分,这里把这层含义放进了 `awarded_at`。

  传 nil 就是"谁也不是",全部为 nil。
  """
  def list_badges(user \\ nil) do
    awarded =
      case user do
        nil ->
          %{}

        %{id: id} ->
          from(a in BadgeAward, where: a.user_id == ^id, select: {a.badge_id, a.awarded_at})
          |> Repo.all()
          |> Map.new()
      end

    from(b in Badge, order_by: [asc: b.id], preload: [:image])
    |> Repo.all()
    |> Enum.map(&{&1, Map.get(awarded, &1.id)})
  end

  @doc """
  后台的勋章列表,带持有人数。

  持有人数是一条 `left_join + count` 现算的 —— core 缓存在 `t_medal.quantity`,
  那是一份会和实际发放对不上的副本。
  """
  def list_all_badges(params \\ %{}) do
    from(b in Badge,
      left_join: a in assoc(b, :awards),
      group_by: b.id,
      select: %{b | holder_count: count(a.id)},
      preload: [:image]
    )
    |> Pagination.paginate(Repo, Pagination.params(params))
  end

  def fetch_badge(id) do
    if Rice.Tsid.valid?(id) do
      case Repo.one(from b in Badge, where: b.id == ^id, preload: [:image]) do
        nil -> {:error, :not_found}
        badge -> {:ok, badge}
      end
    else
      {:error, :not_found}
    end
  end

  def create_badge(attrs) do
    %Badge{}
    |> Badge.changeset(Map.new(attrs, fn {k, v} -> {to_string(k), v} end))
    |> Repo.insert()
    |> case do
      {:ok, badge} -> {:ok, Repo.preload(badge, :image)}
      other -> other
    end
  end

  @doc "持有某枚勋章的人。"
  def list_badge_holders(%Badge{id: id}, params \\ %{}) do
    from(a in BadgeAward,
      where: a.badge_id == ^id,
      preload: [user: :avatar]
    )
    |> filter_holder(params["q"])
    |> Pagination.paginate(Repo, Pagination.params(params))
  end

  defp filter_holder(query, q) when is_binary(q) and q != "" do
    pattern =
      "%" <>
        (q
         |> String.trim()
         |> String.replace("\\", "\\\\")
         |> String.replace("%", "\\%")
         |> String.replace("_", "\\_")) <> "%"

    from a in query,
      join: u in assoc(a, :user),
      where:
        ilike(u.nickname, ^pattern) or ilike(u.email, ^pattern) or ilike(u.phone, ^pattern) or
          ilike(u.handle, ^pattern)
  end

  defp filter_holder(query, _), do: query

  @doc "发一枚勋章。同一枚勋章不会重复发给同一个人。"
  def award_badge(%Badge{} = badge, user) do
    %BadgeAward{}
    |> BadgeAward.changeset(%{badge_id: badge.id, user_id: user.id})
    |> Repo.insert()
  end

  @doc "持有某枚勋章的人数 —— core 把它缓存成 t_medal.quantity,这里现算。"
  def badge_holder_count(%Badge{id: id}),
    do: Repo.aggregate(from(a in BadgeAward, where: a.badge_id == ^id), :count)
end
