defmodule RiceWeb.Api.Admin.BadgeController do
  @moduledoc "勋章的后台维护:建、列、看持有人。"
  use RiceWeb, :controller

  alias Rice.Community

  action_fallback RiceWeb.Api.FallbackController

  def index(conn, params), do: render(conn, :index, page: Community.list_all_badges(params))

  def create(conn, params) do
    with {:ok, badge} <- Community.create_badge(params) do
      conn |> put_status(:created) |> render(:show, badge: badge)
    end
  end

  @doc "持有某枚勋章的人。core 是 /admin/medal/users-holding/page。"
  def holders(conn, %{"badge_id" => badge_id} = params) do
    with {:ok, badge} <- Community.fetch_badge(badge_id) do
      render(conn, :holders, page: Community.list_badge_holders(badge, params))
    end
  end
end
