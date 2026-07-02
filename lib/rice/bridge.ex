defmodule Rice.Bridge do
  @moduledoc """
  Turns a Semi identity into an AT Protocol PDS session.

  A known Semi subject reuses the account rice provisioned for it (decrypt the
  stored password → `createSession`). An unknown subject gets a fresh
  `*.<handle_domain>` account auto-provisioned, its generated password stored
  encrypted, and a session returned.

  Returns `{:ok, %{did, handle, access_jwt, refresh_jwt}}` or `{:error, reason}`.
  """
  alias Rice.{Accounts, PDS, Vault}

  def session_for(%{"sub" => sub} = userinfo) when is_binary(sub) do
    case Accounts.get_link_by_sub(sub) do
      nil -> provision(sub, userinfo)
      link -> login_existing(link)
    end
  end

  defp login_existing(link) do
    with {:ok, password} <- Vault.decrypt(link.account_password_ciphertext),
         {:ok, session} <- PDS.create_session(link.did, password) do
      {:ok, identity(session)}
    else
      {:error, reason} -> {:error, {:login, reason}}
    end
  end

  defp provision(sub, userinfo) do
    password = gen_password()
    base = handle_base(userinfo, sub)

    with {:ok, session} <- create_account(base, sub, password),
         attrs = %{
           semi_sub: sub,
           did: session["did"],
           handle: session["handle"],
           account_password_ciphertext: Vault.encrypt(password)
         },
         {:ok, _link} <- Accounts.create_link(attrs) do
      {:ok, identity(session)}
    else
      {:error, reason} -> {:error, {:provision, reason}}
    end
  end

  # Try `<base>.<domain>`; if the handle is taken, retry once with a short
  # sub-derived suffix (deterministic, effectively unique).
  defp create_account(base, sub, password) do
    domain = PDS.handle_domain()

    case PDS.create_account(%{email: email(base), handle: base <> "." <> domain, password: password}) do
      {:ok, session} ->
        {:ok, session}

      {:error, {:pds, _method, _status, _msg}} ->
        base2 = base <> "-" <> String.slice(sanitize(sub), 0, 6)
        PDS.create_account(%{email: email(base2), handle: base2 <> "." <> domain, password: password})

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_base(userinfo, sub) do
    case sanitize(userinfo["handle"] || "") do
      "" -> "u" <> String.slice(sanitize(sub), 0, 8)
      s -> String.slice(s, 0, 30)
    end
  end

  # AT Protocol handle labels: lowercase [a-z0-9-], no leading/trailing hyphen.
  defp sanitize(s) do
    s
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp email(local), do: local <> "@" <> PDS.email_domain()

  defp gen_password, do: :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)

  defp identity(session) do
    %{
      did: session["did"],
      handle: session["handle"],
      access_jwt: session["accessJwt"],
      refresh_jwt: session["refreshJwt"]
    }
  end
end
