defmodule RiceWeb.Api.Admin.BadgeController do
  @moduledoc "勋章的后台维护:建、列、看持有人。"
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

      {:error, {:unknown_recipients, missing}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: %{to: ["这些用户不存在: " <> Enum.join(missing, ", ")]}})

      {:error, {:invalid_recipients, bad}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          errors: %{to: ["名单里必须是字符串,这些不是: " <> Enum.map_join(bad, ", ", &inspect/1)]}
        })

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  @doc "持有某枚勋章的人。core 是 /admin/medal/users-holding/page。"
  def holders(conn, %{"badge_id" => badge_id} = params) do
    with {:ok, badge} <- Community.fetch_badge(badge_id) do
      render(conn, :holders, page: Community.list_badge_holders(badge, params))
    end
  end
end
