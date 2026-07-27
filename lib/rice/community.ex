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
