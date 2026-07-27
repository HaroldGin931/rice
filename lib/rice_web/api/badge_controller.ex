defmodule RiceWeb.Api.BadgeController do
  @moduledoc "勋章。替代 core 的 /user-medal/page。"
  use RiceWeb, :controller

  action_fallback RiceWeb.Api.FallbackController

  @doc "勋章全集 —— 勋章墙要连没获得的一起灰着显示。"
  def index(conn, _params) do
    render(conn, :index, badges: Rice.Community.list_badges(conn.assigns[:current_user]))
  end

  @doc "只列我获得的,分页。"
  def mine(conn, params) do
    page = Rice.Community.list_badge_awards(conn.assigns.current_user, params)
    render(conn, :mine, page: page)
  end
end
