defmodule RiceWeb.SemiAuthController do
  @moduledoc """
  "Login with Semi" — the Authorization Code + PKCE flow.

  `login`    generates PKCE material, stashes `state` + `code_verifier` in the
             signed session, and redirects the browser to Semi's authorize page.
  `callback` (the registered redirect_uri, `/callback`) verifies `state`, swaps
             the code for tokens, fetches userinfo, and stores the resulting
             identity in the session. Semi tokens are deliberately NOT persisted
             in the browser cookie (the access token is long-lived); only the
             userinfo claims are kept.
  `logout`   clears the Semi identity from the session.
  """
  use RiceWeb, :controller

  alias Rice.SemiOAuth

  def login(conn, _params) do
    if SemiOAuth.configured?() do
      verifier = SemiOAuth.gen_code_verifier()
      state = SemiOAuth.gen_state()
      challenge = SemiOAuth.code_challenge(verifier)

      conn
      |> put_session(:semi_pkce_verifier, verifier)
      |> put_session(:semi_oauth_state, state)
      |> redirect(external: SemiOAuth.authorize_url(state, challenge))
    else
      conn
      |> put_flash(:error, "Semi OAuth 未配置（缺少 SEMI_CLIENT_ID / SEMI_CLIENT_SECRET）")
      |> redirect(to: ~p"/")
    end
  end

  # Semi returned an error instead of a code (e.g. user denied consent).
  def callback(conn, %{"error" => error} = params) do
    detail = params["error_description"] || ""

    conn
    |> reset_pkce()
    |> put_flash(:error, "授权失败: #{error} #{detail}")
    |> redirect(to: ~p"/")
  end

  def callback(conn, %{"code" => code, "state" => state}) do
    expected_state = get_session(conn, :semi_oauth_state)
    verifier = get_session(conn, :semi_pkce_verifier)

    cond do
      is_nil(expected_state) or is_nil(verifier) ->
        conn
        |> reset_pkce()
        |> put_flash(:error, "会话已过期，请重新发起登录")
        |> redirect(to: ~p"/")

      not secure_compare(state, expected_state) ->
        conn
        |> reset_pkce()
        |> put_flash(:error, "state 不匹配，已阻止（可能的 CSRF）")
        |> redirect(to: ~p"/")

      true ->
        complete_login(conn, code, verifier)
    end
  end

  def callback(conn, _params) do
    conn
    |> reset_pkce()
    |> put_flash(:error, "无效的回调参数")
    |> redirect(to: ~p"/")
  end

  def logout(conn, _params) do
    conn
    |> delete_session(:semi_user)
    |> delete_session(:atproto)
    |> put_flash(:info, "已退出登录")
    |> redirect(to: ~p"/")
  end

  defp complete_login(conn, code, verifier) do
    with {:ok, tokens} <- SemiOAuth.exchange_code(code, verifier),
         {:ok, user} <- SemiOAuth.fetch_userinfo(tokens["access_token"]),
         {:ok, atproto} <- Rice.Bridge.session_for(user) do
      conn
      |> reset_pkce()
      |> put_session(:semi_user, Map.take(user, semi_display_keys()))
      |> put_session(:atproto, %{"did" => atproto.did, "handle" => atproto.handle})
      |> put_flash(:info, "已通过 Semi 登录 · AT Protocol 账号 @#{atproto.handle}")
      |> redirect(to: ~p"/")
    else
      {:error, reason} ->
        conn
        |> reset_pkce()
        |> put_flash(:error, "登录失败: #{describe(reason)}")
        |> redirect(to: ~p"/")
    end
  end

  defp semi_display_keys,
    do: ~w(sub handle wallet_address phone_verified email_verified scopes_granted)

  defp reset_pkce(conn) do
    conn
    |> delete_session(:semi_pkce_verifier)
    |> delete_session(:semi_oauth_state)
  end

  defp describe({:token_endpoint, status, body}),
    do: "令牌交换返回 #{status} (#{message_of(body)})"

  defp describe({:userinfo, status, body}),
    do: "获取用户信息返回 #{status} (#{message_of(body)})"

  defp describe({:transport, _reason}), do: "无法连接到 Semi 服务器"

  # Bridge (PDS) failures.
  defp describe({:provision, reason}), do: "创建 AT Protocol 账号失败: #{describe(reason)}"
  defp describe({:login, reason}), do: "登录 AT Protocol 账号失败: #{describe(reason)}"
  defp describe({:pds, _method, status, msg}), do: "PDS 返回 #{status} (#{msg})"
  defp describe({:persist, _changeset}), do: "保存账号映射失败"
  defp describe(:decrypt_failed), do: "凭据解密失败"
  defp describe(other), do: inspect(other)

  defp message_of(%{"error_description" => d}) when is_binary(d), do: d
  defp message_of(%{"error" => e}) when is_binary(e), do: e
  defp message_of(_), do: ""

  # Constant-time-ish comparison for the state token.
  defp secure_compare(a, b) when is_binary(a) and is_binary(b) do
    byte_size(a) == byte_size(b) and :crypto.hash_equals(a, b)
  end

  defp secure_compare(_, _), do: false
end
