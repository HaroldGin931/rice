defmodule RiceWeb.Api.Admin.BadgeController do
  @moduledoc "勋章的后台维护:建、列、看持有人、补发。"
  use RiceWeb, :controller

  alias Rice.Community

  action_fallback RiceWeb.Api.FallbackController

  def index(conn, params), do: render(conn, :index, page: Community.list_all_badges(params))

  @doc """
  建勋章,可以顺带发给一批人。

  core 的 `medal/create` 收一个名单文件,建和发是同一次调用。这里收一个数组
  (解析 Excel 是前端的事),但语义一样:**在同一个事务里**。分两步的话,
  名单里一个笔误就会留下一枚没有持有人的孤儿勋章。
  """
  def create(conn, params) do
    recipients = List.wrap(params["to"])

    case Community.create_badge(Map.drop(params, ["to"]), recipients) do
      {:ok, badge} ->
        conn |> put_status(:created) |> render(:show, badge: badge)

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}

      {:error, reason} ->
        recipient_error(conn, reason)
    end
  end

  @doc "持有某枚勋章的人。core 是 /admin/medal/users-holding/page。"
  def holders(conn, %{"badge_id" => badge_id} = params) do
    with {:ok, badge} <- Community.fetch_badge(badge_id) do
      render(conn, :holders, page: Community.list_badge_holders(badge, params))
    end
  end

  @doc """
  给一枚已有的勋章补发持有人。**core 没有这个接口** —— 那边建完就加不了人,
  漏了谁只能重建一枚同名的。

  和新建时一样,名单里有人认不出来就整批不发;但**已经持有的人不算错**,
  只是不会重复发 —— 补名单时运营粘的常常是完整名单而不是差集。
  """
  def award(conn, %{"badge_id" => badge_id} = params) do
    with {:ok, badge} <- Community.fetch_badge(badge_id),
         {:ok, result} <- Community.award_badge_to(badge, List.wrap(params["to"])) do
      conn |> put_status(:created) |> json(%{data: result})
    else
      # 勋章不存在 —— 交给 fallback 变成 404
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> recipient_error(conn, reason)
    end
  end

  # 收款人相关的报错在建和补发两处是同一套 —— 运营看到的提示也该是同一句话
  defp recipient_error(conn, {:unknown_recipients, missing}) do
    unprocessable(conn, "这些用户不存在: " <> Enum.join(missing, ", "))
  end

  defp recipient_error(conn, {:invalid_recipients, bad}) do
    unprocessable(conn, "名单里必须是字符串,这些不是: " <> Enum.map_join(bad, ", ", &inspect/1))
  end

  defp recipient_error(conn, :no_recipients), do: unprocessable(conn, "名单不能为空")

  defp unprocessable(conn, message) do
    conn |> put_status(:unprocessable_entity) |> json(%{errors: %{to: [message]}})
  end
end
