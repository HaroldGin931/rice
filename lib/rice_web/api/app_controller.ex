defmodule RiceWeb.Api.AppController do
  use RiceWeb, :controller

  action_fallback RiceWeb.Api.FallbackController

  def index(conn, _params) do
    render(conn, :index, apps: Rice.Content.list_apps())
  end
end
