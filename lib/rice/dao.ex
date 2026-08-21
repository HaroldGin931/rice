defmodule Rice.Dao do
  @moduledoc """
  Minimal integration with the xiangjiandao DAO backend, replacing its
  login-token issuance for Semi users.

  The DAO backend (.NET, `xiangjiandao-core`) authenticates its own API with
  an RS256 JWT ("daoJwt") signed by a JWK (a JSON array of JWKs with PKCS#1
  `PrivateKey`) whose `uid` claim must reference an existing `t_user` row in
  the shared MySQL database. Token validation on the .NET side checks only lifetime and
  signature (issuer/audience unvalidated) plus the `type=client` claim.

  `token_for/2` therefore does two things:
    1. ensure a `t_user` row exists for the account's DID (insert if missing);
    2. sign a JWT with the same claims shape as `JwtGenerator.Generate`:
       uid / type / phone / email / phone-region / domain-name.

  Returns `{:ok, "Bearer <jwt>"}` (the Bearer prefix is part of the stored
  token, mirroring the .NET `TokenVo.AccessToken`) or `{:error, reason}`.
  Callers treat failures as non-fatal: a Semi login without a daoJwt still
  yields a working AT Protocol session.

  ## 签名密钥从哪来（2026-08-21 改）

  原来是每次签名去共享 Redis 读 `netcorepal:jwtsettings` —— 那是 core 自己
  写进去的 key。**core 已于 2026-08-21 停机**，于是那把钥匙变成了:
  没有 TTL、没有写入者、**不在任何备份里**（`backup.sh` 里 grep 不到 redis）。
  Redis 的卷一丢就再也生不出来，而 rice 这边的表现只是一行 warning ——
  又一个静默失败。

  现在改成从配置读，由 Nomad Variable `secret/xjdao` 的 `dao_jwks_b64` 注入
  （`DAO_JWKS_B64`），跟着 `backup.sh` 一起备份。**rice 因此不再连 Redis。**

  > ⚠️ **为什么是 base64 而不是直接放 JSON。** Nomad 的 env 模板用
  > go-envparse 解析 `KEY=VALUE`，它会把值里的**双引号吃掉**。第一次上线
  > 就是这么坏的：注入进来的是 `[{PrivateKey:MII...}]`，Jason 在第 2 个字符
  > 报错。本地给环境变量不会复现，只在 Nomad 里炸。

  > 存进去之前做过自检：`PrivateKey`(PKCS#1 DER) 里的模数与 JWK 的 `N` 一致，
  > 2048 位，e=65537。⚠️ `N` 是**标准 base64**（含 `+` `/`），不是 base64url ——
  > 按 base64url 解会得到不同的字节而误判成"钥匙对不上"。

  这条链路本身是**过渡性的**：daoJwt 现在没有任何消费者（C 端产物里
  `/api/v1/` 是 0 处），保留它只是为了 core 的回滚退路。观察期结束后
  连同 `Rice.Dao` 一起删掉。
  """

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

  # ── JWT signing (RS256, key from the configured NetCorePal JWKS) ────────

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

  @doc """
  当前用于签名的 JWK。

  取自配置(`DAO_JWKS`),**不再读 Redis** —— 见模块文档最后一节。
  沿用 core 的选法:数组最后一个。
  """
  def current_jwk do
    case config()[:jwks] do
      json when is_binary(json) and json != "" ->
        case Jason.decode(json) do
          {:ok, [_ | _] = keys} -> {:ok, List.last(keys)}
          {:ok, []} -> {:error, :jwks_empty}
          {:ok, other} -> {:error, {:jwks_unexpected, other}}
          {:error, reason} -> {:error, {:jwks_not_json, reason}}
        end

      _ ->
        {:error, :jwks_not_configured}
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
