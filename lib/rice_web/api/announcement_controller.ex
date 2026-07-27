defmodule RiceWeb.Api.AnnouncementController do
  use RiceWeb, :controller

  action_fallback RiceWeb.Api.FallbackController

  def index(conn, params) do
    page = Rice.Content.list_announcements(params)
    render(conn, :index, page: page)
  end

  def show(conn, %{"id" => id}) do
    with {:ok, announcement} <- Rice.Content.fetch_announcement(id) do
      render(conn, :show, announcement: announcement)
    end
  end
end
