defmodule RiceWeb.PageController do
  use RiceWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
