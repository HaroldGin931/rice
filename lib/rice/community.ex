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

  @doc """
  建一枚勋章,可以顺带发给一批人。

  `recipients` 是手机号 / 邮箱 / handle / DID / rice id 的数组,和发放稻米认的
  写法一样。**建和发在同一个事务里** —— core 也是一次调用干完这两件事
  (`medal/create` 收一个名单文件)。分成两步的话,名单里有一个笔误就会留下
  一枚没有持有人的孤儿勋章,而名单恰恰是最容易出错的地方。

  全有或全无:任何一个收款人解析不出来,勋章也不建。
  """
  def create_badge(attrs, recipients \\ []) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    with {:ok, users} <- resolve_recipients(recipients) do
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:badge, Badge.changeset(%Badge{}, attrs))
      |> award_all(users)
      |> Repo.transaction()
      |> case do
        {:ok, %{badge: badge}} -> {:ok, Repo.preload(badge, :image)}
        {:error, _step, reason, _} -> {:error, reason}
      end
    end
  end

  defp award_all(multi, users) do
    Enum.reduce(users, multi, fn user, acc ->
      Ecto.Multi.insert(acc, {:award, user.id}, fn %{badge: badge} ->
        BadgeAward.changeset(%BadgeAward{}, %{badge_id: badge.id, user_id: user.id})
      end)
    end)
  end

  # 收款人的写法和发放稻米保持一致 —— 运营在两个界面里粘的是同一份名单
  defp resolve_recipients([]), do: {:ok, []}

  defp resolve_recipients(recipients) when is_list(recipients) do
    case Enum.reject(recipients, &is_binary/1) do
      [] -> match_recipients(recipients)
      bad -> {:error, {:invalid_recipients, bad}}
    end
  end

  defp resolve_recipients(_), do: {:error, :invalid_recipients}

  defp match_recipients(recipients) do
    found =
      recipients
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.map(&{&1, Rice.Accounts.find_user(&1)})

    case Enum.filter(found, fn {_, user} -> is_nil(user) end) do
      [] -> {:ok, found |> Enum.map(&elem(&1, 1)) |> Enum.uniq_by(& &1.id)}
      missing -> {:error, {:unknown_recipients, Enum.map(missing, &elem(&1, 0))}}
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
