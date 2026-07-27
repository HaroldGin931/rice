defmodule RiceWeb.Api.NodeController do
  @moduledoc "节点。替代 core 的 /node/list 和 /user/node-user-list。"
  use RiceWeb, :controller

  action_fallback RiceWeb.Api.FallbackController

  def index(conn, _params), do: render(conn, :index, nodes: Rice.Community.list_nodes())

  def members(conn, _params),
    do: render(conn, :members, users: Rice.Community.list_node_members())
end
