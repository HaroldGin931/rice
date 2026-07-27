defmodule RiceWeb.Api.Admin.Auth do
  @moduledoc """
  管理端鉴权。和 C 端的 `RiceWeb.Api.Auth` 是**两套独立的令牌**,
  互相换不过去。

  `require_admin_role` 在服务端强制角色。core 只在前端按 role 隐藏菜单
  (`hideInMenu: !adminAuth`),接口本身不查 —— 那等于没有权限控制,
  知道路径就能调。
  """
  import Plug.Conn
  import Phoenix.Controller, only: [put_view: 2, render: 2]

  alias Rice.Admin.AdminUser

  def fetch_current_admin(conn, _opts) do
    with {:ok, token} <- bearer_token(conn),
         %AdminUser{} = admin <- Rice.Admin.admin_by_token(token) do
      conn |> assign(:current_admin, admin) |> assign(:current_admin_token, token)
    else
      _ -> conn |> assign(:current_admin, nil) |> assign(:current_admin_token, nil)
    end
  end

  def require_admin(conn, _opts) do
    case conn.assigns[:current_admin] do
      %AdminUser{} -> conn
      _ -> deny(conn, :unauthorized, :"401")
    end
  end

  @doc "只有 role=admin 能过。运营(operator)拿到的是只读+内容运营的子集。"
  def require_admin_role(conn, _opts) do
    case conn.assigns[:current_admin] do
      %AdminUser{role: "admin"} -> conn
      _ -> deny(conn, :forbidden, :"403")
    end
  end

  defp deny(conn, status, template) do
    conn
    |> put_status(status)
    |> put_view(json: RiceWeb.Api.ErrorJSON)
    |> render(template)
    |> halt()
  end

  # core 的管理端把裸令牌直接塞进 Authorization,没有 Bearer 前缀。
  # rice 只认标准写法 —— 前端改一行的事。
  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] when byte_size(token) > 0 -> {:ok, String.trim(token)}
      _ -> :error
    end
  end
end
