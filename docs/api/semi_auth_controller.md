# SemiAuthController

「Login with Semi」—— OAuth 2.0 Authorization Code + PKCE。

**这不是 REST API,是浏览器流程。** 前四个是给浏览器跳转用的 HTML 端点,
只有最后一个 `/session/:ticket` 返回 JSON。

和 core 无关 —— core 没有这套东西,是 rice 自己的登录通道。C 端的账号密码登录
在 [session_controller](session_controller.md)。

---

## 流程

```
浏览器 ──GET /login──────────► rice ──302──► Semi 的授权页
                                                  │
浏览器 ◄──302 带 code&state───────────────────────┘
   │
   └──GET /callback?code=…&state=… ──► rice
                                        │ 换令牌、取 userinfo
                                        │ 建/登 PDS 账号
                                        │ 生成一次性 ticket
   ┌────────302 到前端 ?ticket=… ───────┘
   │
前端 ──GET /session/:ticket(跨域)──► rice ──JSON:PDS 会话──► 前端
```

---

## `GET /login`

生成 PKCE 材料,把 `state` 和 `code_verifier` 放进签名过的 session,
跳转到 Semi 的授权页。

Semi OAuth 没配置(缺 `SEMI_CLIENT_ID` / `SEMI_CLIENT_SECRET`)时带一条
flash 消息跳回 `/`。

---

## `GET /callback`

Semi 注册的 redirect_uri。

| 参数 | 说明 |
| --- | --- |
| `code` `state` | 正常回调 |
| `error` `error_description` | 用户拒绝授权等 |

校验 `state`(定长比较,防 CSRF)→ 换令牌 → 取 userinfo → 在 PDS 上建号或登录
→ 生成一次性 ticket → 跳到前端 `?ticket=…`。

任何一步失败都是带 flash 消息跳回 `/`,不是 JSON 错误。

**Semi 的令牌不写进浏览器 cookie** —— access token 是长效的。session 里只留
userinfo 的几个字段(`sub` `handle` `wallet_address` `phone_verified`
`email_verified` `scopes_granted`)和 `did` / `handle`。

---

## `GET /logout`

清掉 session 里的 Semi 身份,跳回 `/`。

不影响 rice 的 API 令牌 —— 那个是 [`DELETE /api/session`](session_controller.md#delete-apisession)。

---

## `GET /session/:ticket`

用一次性 ticket 换 PDS 会话。**跨域**调用,由前端的 `/semi-callback` 页面发起。

### 响应 `200`

```json
{
  "service": "https://pds.xjdao.xyz",
  "did": "did:plc:abc123",
  "handle": "alice.web5.xjdao.xyz",
  "accessJwt": "…",
  "refreshJwt": "…",
  "daoJwt": "Bearer …"
}
```

注意这个响应**没有 `data` 包装** —— 它不走 API 的那套约定,是握手协议的一部分。
字段名也是 AT Protocol 的 camelCase。

`daoJwt` 只在 DAO 集成开着且成功时出现。

### 响应头

```
Access-Control-Allow-Origin: <配置的前端 origin>
Vary: origin
Cache-Control: no-store
```

CORS 只放行配置里的那一个 origin。

### 错误

| 状态码 | body |
| --- | --- |
| `404` | `{"error": "invalid_or_expired_ticket"}` |

ticket **用一次就作废**,过期也是同一个响应。
