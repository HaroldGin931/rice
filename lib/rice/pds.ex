defmodule Rice.PDS do
  @moduledoc """
  Minimal AT Protocol PDS client. rice runs on the same host as the PDS and
  reaches it over the internal address (no Cloudflare hop). Only the two XRPC
  procedures the identity bridge needs are implemented.
  """

  @doc "com.atproto.server.createSession — {identifier, password} → session."
  def create_session(identifier, password) do
    post("com.atproto.server.createSession", %{
      "identifier" => identifier,
      "password" => password
    })
  end

  @doc "com.atproto.server.createAccount — {email, handle, password} → session."
  def create_account(%{email: email, handle: handle, password: password}) do
    post("com.atproto.server.createAccount", %{
      "email" => email,
      "handle" => handle,
      "password" => password
    })
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
  def handle_domain, do: config()[:handle_domain]
  def email_domain, do: config()[:email_domain]

  defp config, do: Application.fetch_env!(:rice, :pds)
end
