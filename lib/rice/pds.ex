defmodule Rice.PDS do
  @moduledoc """
  Minimal AT Protocol PDS client. rice runs on the same host as the PDS and
  reaches it over the internal address (no Cloudflare hop). Only the two XRPC
  procedures the identity bridge needs are implemented.

  实现 `Rice.PDS.Api`;测试通过 `config :rice, :pds_client` 换成 Mox。
  """
  @behaviour Rice.PDS.Api

  @doc "com.atproto.server.createSession — {identifier, password} → session."
  @impl true
  def create_session(identifier, password) do
    post("com.atproto.server.createSession", %{
      "identifier" => identifier,
      "password" => password
    })
  end

  @doc "com.atproto.server.createAccount — {email, handle, password} → session."
  @impl true
  def create_account(%{email: email, handle: handle, password: password}) do
    post("com.atproto.server.createAccount", %{
      "email" => email,
      "handle" => handle,
      "password" => password
    })
  end

  @doc "com.atproto.repo.getRecord for the actor's profile. {:ok, record} | :missing | {:error, _}."
  @impl true
  def get_profile(access_jwt, did) do
    url =
      base_url() <>
        "/xrpc/com.atproto.repo.getRecord?" <>
        URI.encode_query(%{
          "repo" => did,
          "collection" => "app.bsky.actor.profile",
          "rkey" => "self"
        })

    case Req.get(url, auth: {:bearer, access_jwt}, receive_timeout: 20_000) do
      {:ok, %{status: 200, body: %{"value" => record}}} ->
        {:ok, record}

      {:ok, %{status: 400, body: %{"error" => "RecordNotFound"}}} ->
        :missing

      {:ok, %{status: status, body: body}} ->
        {:error, {:pds, "getRecord", status, xrpc_error(body)}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  @doc "com.atproto.repo.putRecord — write the actor's profile record."
  @impl true
  def put_profile(access_jwt, did, %{} = record) do
    url = base_url() <> "/xrpc/com.atproto.repo.putRecord"

    body = %{
      "repo" => did,
      "collection" => "app.bsky.actor.profile",
      "rkey" => "self",
      "record" => Map.put(record, "$type", "app.bsky.actor.profile")
    }

    case Req.post(url, json: body, auth: {:bearer, access_jwt}, receive_timeout: 20_000) do
      {:ok, %{status: 200, body: ok}} ->
        {:ok, ok}

      {:ok, %{status: status, body: body}} ->
        {:error, {:pds, "putRecord", status, xrpc_error(body)}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  @doc """
  com.atproto.admin.updateAccountPassword —— 重置密码。

  ⚠️ 这个接口要的是**完整的 HTTP Basic 头**(`Basic base64(admin:密码)`),
  不是裸密码。2026-07 生产上 `BlueSky__AdminToken` 配成了裸密码,
  reset-password 一直 500。
  """
  @impl true
  def update_account_password(did, password) do
    url = base_url() <> "/xrpc/com.atproto.admin.updateAccountPassword"

    case Req.post(url,
           json: %{"did" => did, "password" => password},
           headers: [{"authorization", admin_auth()}],
           receive_timeout: 20_000
         ) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, {:pds, "updateAccountPassword", status, xrpc_error(body)}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp admin_auth do
    case config()[:admin_password] do
      nil -> raise "PDS 管理凭据未配置(PDS_ADMIN_PASSWORD)"
      password -> "Basic " <> Base.encode64("admin:" <> password)
    end
  end

  # Both procedures return the same success shape: did/handle/accessJwt/refreshJwt.
  defp post(method, body) do
    url = base_url() <> "/xrpc/" <> method

    case Req.post(url, json: body, receive_timeout: 20_000) do
      {:ok, %{status: 200, body: %{"did" => _} = ok}} ->
        {:ok, ok}

      {:ok, %{status: status, body: body}} ->
        {:error, {:pds, method, status, xrpc_error(body)}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  # XRPC errors: %{"error" => "Name", "message" => "..."}
  defp xrpc_error(%{"error" => e, "message" => m}), do: "#{e}: #{m}"
  defp xrpc_error(%{"error" => e}), do: e
  defp xrpc_error(_), do: "unknown error"

  defp base_url, do: config()[:base_url]
  @impl true
  def handle_domain, do: config()[:handle_domain]

  @impl true
  def email_domain, do: config()[:email_domain]

  defp config, do: Application.fetch_env!(:rice, :pds)
end
