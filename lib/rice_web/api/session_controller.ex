defmodule RiceWeb.Api.SessionController do
  @moduledoc "登录 / 登出。替代 core 的 /user/login。"
  use RiceWeb, :controller

  alias Rice.Accounts

  action_fallback RiceWeb.Api.FallbackController

  def create(conn, %{"identifier" => identifier, "password" => password})
      when is_binary(identifier) and is_binary(password) do
    case Accounts.login(identifier, password) do
      {:ok, result} ->
        conn |> put_view(json: RiceWeb.Api.SessionJSON) |> render(:show, result)

      {:error, :account_disabled} ->
        conn |> put_status(:forbidden) |> json(%{errors: %{detail: "该账号已被禁用"}})

      {:error, :invalid_credentials} ->
        # 不区分"账号不存在"和"密码错误" —— 区分了就等于一个账号枚举接口
        conn |> put_status(:unauthorized) |> json(%{errors: %{detail: "账号或密码错误"}})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: %{detail: "缺少 identifier 或 password"}})
  end

  def delete(conn, _params) do
    if token = conn.assigns[:current_token], do: Accounts.revoke_token(token)
    send_resp(conn, :no_content, "")
  end
end
