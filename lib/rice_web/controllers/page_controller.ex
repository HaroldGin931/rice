defmodule RiceWeb.PageController do
  use RiceWeb, :controller

  def home(conn, _params) do
    render(conn, :home, semi_user: get_session(conn, :semi_user))
  end
end
