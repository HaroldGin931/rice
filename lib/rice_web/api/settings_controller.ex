defmodule RiceWeb.Api.SettingsController do
  use RiceWeb, :controller

  action_fallback RiceWeb.Api.FallbackController

  def foundation(conn, _params) do
    render(conn, :foundation, site: Rice.Settings.get_site())
  end
end
