defmodule RiceWeb.Api.Admin.PasswordController do
  @moduledoc "管理员忘记密码。凭手机验证码重置,成功后踢掉全部会话。"
  use RiceWeb, :controller

  action_fallback RiceWeb.Api.FallbackController

  @doc "发重置码。手机号不是管理员时也返回 202 —— 不泄露谁是管理员。"
  def challenge(conn, params) do
    case Rice.Admin.send_reset_code(params["phone_region"] || "86", params["phone"] || "") do
      {:ok, _} ->
        send_resp(conn, :accepted, "")

      {:error, :too_many_requests} ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{errors: %{detail: "操作过于频繁,请稍后再试"}})

      {:error, _} ->
        send_resp(conn, :accepted, "")
    end
  end

  def create(conn, params) do
    case Rice.Admin.reset_password(
           params["phone_region"] || "86",
           params["phone"] || "",
           params["code"] || "",
           params["password"] || ""
         ) do
      {:ok, _admin} ->
        send_resp(conn, :no_content, "")

      {:error, %Ecto.Changeset{} = cs} ->
        {:error, cs}

      {:error, :too_many_attempts} ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{errors: %{detail: "尝试次数过多,请重新获取验证码"}})

      {:error, _} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: %{code: ["验证码不正确"]}})
    end
  end
end
