defmodule RiceWeb.Api.BannerController do
  use RiceWeb, :controller

  action_fallback RiceWeb.Api.FallbackController

  def index(conn, _params) do
    render(conn, :index, banners: Rice.Content.list_banners())
  end
end
