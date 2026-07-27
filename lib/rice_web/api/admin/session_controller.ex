defmodule RiceWeb.Api.Admin.SessionController do
  @moduledoc """
  管理端登录。两步:

    1. `POST /api/admin/session/challenge` —— 验密码,对了才发短信验证码
    2. `POST /api/admin/session` —— 密码 + 验证码换令牌

  core 的第一步只回一个 bool,验证码要前端自己去调**公开的** `/sms/send`,
  也就是不知道密码也能让管理员的手机响。这里把发码放到密码验过之后。
  """
  use RiceWeb, :controller

  action_fallback RiceWeb.Api.FallbackController

  def challenge(conn, params) do
    case Rice.Admin.start_login(
           params["phone_region"] || "86",
           params["phone"] || "",
           params["password"] || ""
         ) do
      {:ok, _} -> send_resp(conn, :accepted, "")
      {:error, :too_many_requests} -> too_many(conn)
      # 密码错 / 账号不存在 / 账号停用 —— 一律同一个响应
      {:error, _} -> invalid(conn)
    end
  end

  def create(conn, params) do
    case Rice.Admin.login(
           params["phone_region"] || "86",
           params["phone"] || "",
           params["password"] || "",
           params["code"] || ""
         ) do
      {:ok, admin, token} ->
        conn |> put_status(:created) |> render(:show, admin: admin, token: token)

      {:error, :too_many_attempts} ->
        too_many(conn)

      {:error, _} ->
        invalid(conn)
    end
  end

  def delete(conn, _params) do
    Rice.Admin.revoke_token(conn.assigns.current_admin_token)
    send_resp(conn, :no_content, "")
  end

  defp invalid(conn) do
    conn
    |> put_status(:unauthorized)
    |> json(%{errors: %{detail: "手机号、密码或验证码不正确"}})
  end

  defp too_many(conn) do
    conn
    |> put_status(:too_many_requests)
    |> json(%{errors: %{detail: "操作过于频繁,请稍后再试"}})
  end
end
