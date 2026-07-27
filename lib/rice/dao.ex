defmodule Rice.Dao do
  @moduledoc """
  Minimal integration with the xiangjiandao DAO backend, replacing its
  login-token issuance for Semi users.

  The DAO backend (.NET, `xiangjiandao-core`) authenticates its own API with
  an RS256 JWT ("daoJwt") whose signing keys live in the shared Redis under
  `netcorepal:jwtsettings` (a JSON array of JWKs with PKCS#1 `PrivateKey`),
  and whose `uid` claim must reference an existing `t_user` row in the shared
  MySQL database. Token validation on the .NET side checks only lifetime and
  signature (issuer/audience unvalidated) plus the `type=client` claim.

  `token_for/2` therefore does two things:
    1. ensure a `t_user` row exists for the account's DID (insert if missing);
    2. sign a JWT with the same claims shape as `JwtGenerator.Generate`:
       uid / type / phone / email / phone-region / domain-name.

  Returns `{:ok, "Bearer <jwt>"}` (the Bearer prefix is part of the stored
  token, mirroring the .NET `TokenVo.AccessToken`) or `{:error, reason}`.
  Callers treat failures as non-fatal: a Semi login without a daoJwt still
  yields a working AT Protocol session.
  """
  @jwks_redis_key "netcorepal:jwtsettings"

  def enabled? do
    config()[:mysql_password] not in [nil, ""]
  end

  def token_for(identity, userinfo) do
    with {:ok, uid} <- ensure_user(identity, userinfo),
         {:ok, jwt} <- mint_jwt(uid, identity) do
      {:ok, "Bearer " <> jwt}
    end
  end

  # ── t_user provisioning ─────────────────────────────────────────────────

  defp ensure_user(identity, userinfo) do
    case MyXQL.query(
           Rice.DaoSql,
           "SELECT id, disable FROM t_user WHERE did = ? AND deleted = 0 LIMIT 1",
           [identity.did]
         ) do
      {:ok, %{rows: [[id, disable]]}} ->
        if disable == 1, do: {:error, :user_disabled}, else: {:ok, id}

      {:ok, %{rows: []}} ->
        insert_user(identity, userinfo)

      {:error, reason} ->
        {:error, {:mysql, reason}}
    end
  end

  defp insert_user(identity, userinfo) do
    id = Ecto.UUID.generate()
    nick = nick_name(userinfo, identity.handle)

    email =
      identity.handle |> String.split(".") |> hd() |> Kernel.<>("@" <> Rice.PDS.email_domain())

    sql = """
    INSERT INTO t_user
      (id, email, phone, phone_region, avatar, nick_name, introduction,
       domain_name, did, score, node_user, disable, row_version,
       created_at, created_by, updated_at, updated_by, deleted)
    VALUES (?, ?, '', '', '', ?, '', ?, ?, 0, 0, 0, 0, NOW(), 'rice', NOW(), 'rice', 0)
    """

    case MyXQL.query(Rice.DaoSql, sql, [id, email, nick, identity.handle, identity.did]) do
      {:ok, _} -> {:ok, id}
      {:error, reason} -> {:error, {:mysql, reason}}
    end
  end

  defp nick_name(userinfo, pds_handle) do
    case String.trim(userinfo["handle"] || "") do
      "" -> pds_handle |> String.split(".") |> hd()
      s -> String.slice(s, 0, 64)
    end
  end

  # ── JWT signing (RS256, key from the DAO's NetCorePal JWKS in Redis) ────

  defp mint_jwt(uid, identity) do
    with {:ok, %{"Kid" => kid, "PrivateKey" => pk_b64}} <- current_jwk() do
      cfg = config()
      now = System.os_time(:second)
      exp = now + cfg[:jwt_exp_minutes] * 60

      email =
        identity.handle |> String.split(".") |> hd() |> Kernel.<>("@" <> Rice.PDS.email_domain())

      header = %{"alg" => "RS256", "typ" => "JWT", "kid" => kid}

      claims = %{
        "uid" => uid,
        "type" => "client",
        "phone" => "",
        "email" => email,
        "phone-region" => "",
        "domain-name" => identity.handle,
        "iss" => cfg[:jwt_issuer],
        "aud" => cfg[:jwt_audience],
        "nbf" => now,
        "iat" => now,
        "exp" => exp
      }

      signing_input = b64url(Jason.encode!(header)) <> "." <> b64url(Jason.encode!(claims))

      with {:ok, key} <- decode_private_key(pk_b64) do
        signature = :public_key.sign(signing_input, :sha256, key)
        {:ok, signing_input <> "." <> b64url(signature)}
      end
    end
  end

  defp current_jwk do
    with {:ok, json} when is_binary(json) <-
           Redix.command(Rice.DaoRedis, ["GET", @jwks_redis_key]),
         {:ok, [_ | _] = keys} <- Jason.decode(json) do
      {:ok, List.last(keys)}
    else
      {:ok, nil} -> {:error, :jwks_not_found}
      {:error, reason} -> {:error, {:redis, reason}}
      other -> {:error, {:jwks_unexpected, other}}
    end
  end

  # PrivateKey is standard-base64 DER: PKCS#1 (`RSAPrivateKey`) from
  # RSA.ExportRSAPrivateKey, with a PKCS#8 fallback just in case.
  defp decode_private_key(b64) do
    case Base.decode64(b64) do
      {:ok, der} -> parse_rsa_der(der)
      :error -> {:error, :bad_private_key_base64}
    end
  end

  defp parse_rsa_der(der) do
    {:ok, :public_key.der_decode(:RSAPrivateKey, der)}
  rescue
    _ ->
      try do
        case :public_key.der_decode(:PrivateKeyInfo, der) do
          {:PrivateKeyInfo, _, _, wrapped, _} ->
            {:ok, :public_key.der_decode(:RSAPrivateKey, wrapped)}

          other ->
            {:error, {:unsupported_key, other}}
        end
      rescue
        e -> {:error, {:bad_private_key, e}}
      end
  end

  defp b64url(bin), do: Base.url_encode64(bin, padding: false)

  defp config, do: Application.fetch_env!(:rice, :dao)
end
