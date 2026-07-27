defmodule RiceWeb.Api.Auth do
  @moduledoc """
  Bearer 令牌认证。

  `fetch_current_user` 只做解析,不拒绝;`require_authenticated_user` 才拦。
  分开是为了让同一个接口能有"登录可见更多"的语义,而不必写两套。
  """
  import Plug.Conn
  import Phoenix.Controller, only: [put_view: 2, render: 2]

  alias Rice.Accounts

  def fetch_current_user(conn, _opts) do
    with {:ok, token} <- bearer_token(conn),
         %Accounts.User{} = user <- Accounts.user_by_token(token) do
      conn |> assign(:current_user, user) |> assign(:current_token, token)
    else
      _ -> conn |> assign(:current_user, nil) |> assign(:current_token, nil)
    end
  end

  def require_authenticated_user(conn, _opts) do
    case conn.assigns[:current_user] do
      %Accounts.User{} ->
        conn

      _ ->
        conn
        |> put_status(:unauthorized)
        |> put_view(json: RiceWeb.Api.ErrorJSON)
        |> render(:"401")
        |> halt()
    end
  end

  # core 那边 daoJwt 存的就是完整的 "Bearer xxx" 串,这里只认标准头。
  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] when byte_size(token) > 0 -> {:ok, String.trim(token)}
      _ -> :error
    end
  end
end
