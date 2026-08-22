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

  # ── daoJwt 校验（老会话兜底，2026-08-22 加）────────────────────────────

  @doc """
  校验一枚 core 时代的 daoJwt,返回 `{:ok, uid}`(即 `t_user.id`,在 rice 这边
  就是 `users.legacy_id`)。

  为什么需要它:2026-08-21 切到 rice 之后,浏览器里存的还是 core 签的 daoJwt,
  而 rice 只认自己签发的不透明令牌 —— 于是 2000 多个已登录用户的每一个
  `/api/users/me` 都是 401。页面还能浏览(PDS 会话没坏),但余额、发稻米、
  提案全哑掉,而且**前端把余额缺失当成 0**,报出来的是"请输入正确格式"。

  这里只做**读侧兜底**:认这张老票,让人不必被迫重新登录。签发侧不受影响 ——
  新登录拿到的仍然是可撤销的 `api_tokens`。等老票自然过期(30 天,即最迟
  2026-09-20)这段代码连同 `Rice.Dao` 一起删。

  校验的东西和 core 的 .NET 侧一致:签名 + 生命期 + `type=client`。
  issuer/audience 那边就没校验,这里也不校验 —— 校验了反而会把 core 签的票
  挡在外面。
  """
  def verify_jwt("Bearer " <> rest), do: verify_jwt(String.trim(rest))

  def verify_jwt(token) when is_binary(token) do
    with [h, p, sig] <- String.split(token, ".", parts: 3),
         {:ok, header} <- decode_part(h),
         {:ok, claims} <- decode_part(p),
         {:ok, signature} <- Base.url_decode64(sig, padding: false),
         :ok <- check_alg(header),
         {:ok, jwk} <- jwk_for(header["kid"]),
         {:ok, public_key} <- public_key_from(jwk),
         true <- :public_key.verify(h <> "." <> p, :sha256, signature, public_key),
         :ok <- check_lifetime(claims),
         :ok <- check_type(claims),
         uid when is_binary(uid) and uid != "" <- claims["uid"] do
      {:ok, uid}
    else
      false -> {:error, :bad_signature}
      :error -> {:error, :malformed}
      {:error, _} = err -> err
      _ -> {:error, :malformed}
    end
  end

  def verify_jwt(_), do: {:error, :malformed}

  defp decode_part(part) do
    with {:ok, json} <- Base.url_decode64(part, padding: false),
         {:ok, map} when is_map(map) <- Jason.decode(json) do
      {:ok, map}
    else
      _ -> {:error, :malformed}
    end
  end

  defp check_alg(%{"alg" => "RS256"}), do: :ok
  defp check_alg(_), do: {:error, :unsupported_alg}

  # 没有 kid 或对不上就退回"数组最后一个" —— 和签名侧的选法一致。
  defp jwk_for(kid) do
    with {:ok, json} <- jwks_json(),
         {:ok, keys} when is_list(keys) <- Jason.decode(json) do
      case Enum.find(keys, &(is_map(&1) and &1["Kid"] == kid)) do
        nil -> if keys == [], do: {:error, :jwks_empty}, else: {:ok, List.last(keys)}
        key -> {:ok, key}
      end
    else
      {:ok, _} -> {:error, :jwks_unexpected}
      {:error, _} = err -> err
      _ -> {:error, :jwks_not_configured}
    end
  end

  defp jwks_json do
    case config()[:jwks] do
      json when is_binary(json) and json != "" -> {:ok, json}
      _ -> {:error, :jwks_not_configured}
    end
  end

  # 从**私钥**推公钥,而不是读 JWK 的 `N`/`E`。
  # ⚠️ NetCorePal 写进去的 `N` 是标准 base64(含 `+` `/`),不是 base64url ——
  # 按 base64url 解会得到不同的字节,校验必然失败且看着像"钥匙对不上"。
  # 私钥 DER 我们本来就要解,直接取里面的模数和指数,绕开这个坑。
  defp public_key_from(%{"PrivateKey" => pk_b64}) do
    case decode_private_key(pk_b64) do
      {:ok, {:RSAPrivateKey, _v, n, e, _d, _p, _q, _e1, _e2, _c, _other}} ->
        {:ok, {:RSAPublicKey, n, e}}

      {:ok, other} ->
        {:error, {:unsupported_key, other}}

      {:error, _} = err ->
        err
    end
  end

  defp public_key_from(_), do: {:error, :jwk_without_private_key}

  # 允许 60 秒时钟偏差 —— 两台机器的 NTP 不一定一致。
  @leeway 60

  defp check_lifetime(claims) do
    now = System.os_time(:second)
    exp = as_int(claims["exp"])
    nbf = as_int(claims["nbf"])

    cond do
      is_nil(exp) -> {:error, :no_exp}
      now > exp + @leeway -> {:error, :expired}
      is_integer(nbf) and now < nbf - @leeway -> {:error, :not_yet_valid}
      true -> :ok
    end
  end

  defp as_int(v) when is_integer(v), do: v

  defp as_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp as_int(_), do: nil

  defp check_type(%{"type" => "client"}), do: :ok
  defp check_type(_), do: {:error, :not_client_token}

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
