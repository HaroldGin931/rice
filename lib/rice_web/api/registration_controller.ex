defmodule RiceWeb.Api.RegistrationController do
  @moduledoc """
  注册。替代 core 的 `/user/pre-register` + `/user/register`。

  core 把预注册票放在 Redis 的一个 hash 里(30 分钟 TTL),这里改成签名票据:
  验证码校验通过后签发,注册时验签。没有服务端状态,也就没有"Redis 重启后
  用户卡在注册中途"这种问题。
  """
  use RiceWeb, :controller

  alias Rice.Accounts

  action_fallback RiceWeb.Api.FallbackController

  @ticket_salt "registration ticket"
  @ticket_max_age 1800

  @doc "第一步:校验验证码,换一张注册票。"
  def verify(conn, params) do
    channel = params["channel"]
    {target, contact} = contact_for(channel, params)

    case Accounts.verify_code(channel, target, "register", params["code"] || "") do
      :ok ->
        ticket = Phoenix.Token.sign(RiceWeb.Endpoint, @ticket_salt, contact)
        json(conn, %{data: %{ticket: ticket, expires_in: @ticket_max_age}})

      {:error, :too_many_attempts} ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{errors: %{detail: "尝试次数过多,请重新获取验证码"}})

      {:error, :code_expired} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: %{code: ["验证码已过期"]}})

      {:error, _} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: %{code: ["验证码不正确"]}})
    end
  end

  @doc "第二步:凭票 + 公开昵称 + 密码完成注册,账号标识由服务端分配。"
  def create(conn, params) do
    with {:ok, contact} <- verify_ticket(params["ticket"]),
         {:ok, nickname} <- fetch_nickname(params),
         {:ok, password} <- fetch_password(params) do
      attrs =
        contact
        |> atomize()
        |> Map.merge(%{
          handle: registration_handle(params["ticket"]),
          nickname: nickname,
          password: password
        })

      case Accounts.register(attrs) do
        {:ok, result} ->
          conn
          |> put_status(:created)
          |> put_view(json: RiceWeb.Api.SessionJSON)
          |> render(:show, result)

        {:error, :contact_taken} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{errors: %{detail: "该手机号或邮箱已被使用"}})

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset}

        {:error, _} ->
          conn |> put_status(:bad_gateway) |> json(%{errors: %{detail: "创建账号失败"}})
      end
    end
  end

  defp verify_ticket(ticket) when is_binary(ticket) do
    case Phoenix.Token.verify(RiceWeb.Endpoint, @ticket_salt, ticket, max_age: @ticket_max_age) do
      {:ok, contact} -> {:ok, contact}
      {:error, _} -> {:error, :invalid_ticket}
    end
  end

  defp verify_ticket(_), do: {:error, :invalid_ticket}

  # 同一张已验签的票重试时保持同一账号标识;不把手机号或邮箱放进公开 handle。
  defp registration_handle(ticket) do
    suffix = :crypto.hash(:sha256, ticket) |> binary_part(0, 12) |> Base.encode16(case: :lower)
    "u#{suffix}.#{Rice.PDS.Api.impl().handle_domain()}"
  end

  defp fetch_nickname(%{"nickname" => nickname}) when is_binary(nickname) do
    nickname = String.trim(nickname)
    if String.length(nickname) in 1..64, do: {:ok, nickname}, else: {:error, :invalid_nickname}
  end

  defp fetch_nickname(_), do: {:error, :invalid_nickname}

  # 密码不落 rice 的库,但长度还是要挡一道 —— PDS 那边的下限是 8
  defp fetch_password(%{"password" => password})
       when is_binary(password) and byte_size(password) >= 8,
       do: {:ok, password}

  defp fetch_password(_), do: {:error, :weak_password}

  defp contact_for("sms", params) do
    region = params["phone_region"] || "86"
    phone = params["phone"] || ""
    {Rice.Accounts.phone_target(region, phone), %{"phone" => phone, "phone_region" => region}}
  end

  defp contact_for("email", params) do
    email = params["email"] || ""
    {email, %{"email" => email}}
  end

  defp contact_for(_, _), do: {"", %{}}

  defp atomize(map), do: Map.new(map, fn {k, v} -> {String.to_existing_atom(k), v} end)
end
