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
  require Logger

  def session_for(%{"sub" => sub} = userinfo) when is_binary(sub) do
    result =
      case Accounts.get_link_by_sub(sub) do
        nil -> provision(sub, userinfo)
        link -> login_existing(link)
      end

    with {:ok, identity} <- result do
      ensure_profile(identity, userinfo)
      {:ok, Map.put(identity, :dao_jwt, dao_jwt(identity, userinfo))}
    end
  end

  # Best-effort DAO token (t_user row + RS256 daoJwt). A Semi login without
  # it still yields a working AT Protocol session; DAO features need it.
  defp dao_jwt(identity, userinfo) do
    if Rice.Dao.enabled?() do
      case Rice.Dao.token_for(identity, userinfo) do
        {:ok, token} ->
          token

        {:error, reason} ->
          Logger.warning("bridge: dao token failed for #{identity.did}: #{inspect(reason)}")
          nil
      end
    end
  end

  # Write an initial app.bsky.actor.profile if the account has none — covers
  # both freshly provisioned accounts and older ones created before profile
  # bootstrap existed. Never overwrites an existing profile (the user may have
  # edited it in the app), and never fails the login: profile is cosmetic.
  defp ensure_profile(identity, userinfo) do
    case PDS.get_profile(identity.access_jwt, identity.did) do
      :missing ->
        display_name = display_name(userinfo, identity.handle)

        case PDS.put_profile(identity.access_jwt, identity.did, %{"displayName" => display_name}) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning("bridge: profile bootstrap failed for #{identity.did}: #{inspect(reason)}")
        end

      {:ok, _record} ->
        :ok

      {:error, reason} ->
        Logger.warning("bridge: profile check failed for #{identity.did}: #{inspect(reason)}")
    end
  end

  # Semi userinfo has no nickname/avatar; the best initial display name is the
  # Semi handle, falling back to the first label of the PDS handle.
  defp display_name(userinfo, pds_handle) do
    case String.trim(userinfo["handle"] || "") do
      "" -> pds_handle |> String.split(".") |> hd()
      s -> String.slice(s, 0, 64)
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
