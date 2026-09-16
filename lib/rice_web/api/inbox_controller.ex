defmodule RiceWeb.Api.InboxController do
  use RiceWeb, :controller
  def index(conn, _), do: json(conn, %{notifications: Rice.Inbox.list(conn.assigns.current_user)})

  def read(conn, _) do
    Rice.Inbox.mark_read(conn.assigns.current_user)
    send_resp(conn, :no_content, "")
  end
end
