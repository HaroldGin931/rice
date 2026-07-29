# SessionController

登录 / 登出。替代 core 的 `/user/login`。

共通约定见 [README](README.md)。

---

## `POST /api/session`

匿名可用。

### 请求

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `identifier` | string | 是 | handle、DID、rice id、手机号或邮箱 |
| `password` | string | 是 | |

### 响应 `200`

```json
{
  "data": {
    "token": "…",
    "user": { "…": "…" },
    "pds": {
      "service": "https://pds.xjdao.xyz",
      "did": "did:plc:…",
      "handle": "…",
      "access_jwt": "…",
      "refresh_jwt": "…"
    }
  }
}
```

`token` 用于 `/api/*`;`pds` 那组给前端的 AT Protocol Agent 用。两者独立,
rice 不代管 PDS 凭据。

`user` 的字段见 [user_controller](user_controller.md#用户对象)。

### 错误

| 状态码 | body | 什么时候 |
| --- | --- | --- |
| `401` | `{"errors":{"detail":"账号或密码错误"}}` | 账号不存在**或**密码错 |
| `403` | `{"errors":{"detail":"该账号已被禁用"}}` | 被后台停用 |
| `422` | `{"errors":{"detail":"缺少 identifier 或 password"}}` | |

账号不存在和密码错返回的是同一个东西 —— 区分了就等于一个账号枚举接口。
连**耗时**也对齐:用户不存在时照样走一次 PDS,不让响应时间泄露。

---

## `DELETE /api/session`

登出。需要登录。

撤销当前这一把令牌(删行,立刻失效),别的设备上的会话不受影响。

### 响应

`204`,body 为空。

没带令牌是 `401`。

## 密码归谁管

密码的权威在 PDS。rice 拿 handle + 密码去 PDS 换会话,换到了才发自己的令牌。
rice 库里既没有密码也没有密码摘要。
