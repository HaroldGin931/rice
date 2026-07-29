# RegistrationController

注册。替代 core 的 `/user/pre-register` + `/user/register`。

两步:先用验证码换一张**注册票**,再凭票 + handle + 密码开户。

core 把预注册状态放在 Redis 的一个 hash 里(30 分钟 TTL)。这里改成签名票据
—— 没有服务端状态,也就没有「Redis 重启后用户卡在注册中途」这种问题。

共通约定见 [README](README.md)。

---

## `POST /api/registrations/verification`

第一步:校验验证码,换一张注册票。

### 请求

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `channel` | string | 是 | `sms` 或 `email` |
| `code` | string | 是 | `purpose=register` 的验证码 |
| `phone` | string | `channel=sms` 时 | |
| `phone_region` | string | 否 | 默认 `86` |
| `email` | string | `channel=email` 时 | |

### 响应 `200`

```json
{"data": {"ticket": "SFMyNTY.g2gDbQ…", "expires_in": 1800}}
```

票有效期 **30 分钟**,里面签着这次验证过的联系方式 —— 第二步不用再传一遍,
也改不成别人的号码。

### 错误

| 状态码 | body | 什么时候 |
| --- | --- | --- |
| `422` | `{"errors":{"code":["验证码不正确"]}}` | 码错 |
| `422` | `{"errors":{"code":["验证码已过期"]}}` | 超过 30 分钟 |
| `429` | | 试错超过 5 次,要重新发码 |

---

## `POST /api/registrations`

第二步:凭票开户。

### 请求

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `ticket` | string | 是 | 第一步拿到的票 |
| `handle` | string | 是 | AT Protocol handle,全局唯一 |
| `password` | string | 是 | 至少 8 位 |

联系方式从票里取,**不从请求体取**。

### 响应 `201`

和登录同形:

```json
{
  "data": {
    "token": "…",
    "user": { "id": "…", "did": "did:plc:…", "handle": "…", "…": "…" },
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

`token` 是 rice 自己的令牌。`pds` 那组是 AT Protocol 的会话,前端的 Agent
直接拿它跟 PDS 说话 —— **rice 不代管这组凭据**,也不存密码。

`user` 的字段见 [user_controller](user_controller.md#用户对象)。

### 错误

| 状态码 | body | 什么时候 |
| --- | --- | --- |
| `422` | `{"errors":{"detail":"注册票据无效或已过期,请重新验证"}}` | 票不对 |
| `422` | `{"errors":{"detail":"缺少 handle"}}` | |
| `422` | `{"errors":{"detail":"密码至少 8 位"}}` | |
| `422` | `{"errors":{"detail":"该手机号或邮箱已被使用"}}` | |
| `422` | `{"errors":{"handle":["…"]}}` | PDS 拒绝这个 handle(重复、格式不对) |
| `502` | `{"errors":{"detail":"创建账号失败"}}` | PDS 不可用 |

## 密码归谁管

**密码的权威在 PDS**,rice 不存密码,也不存摘要。登录是拿 handle + 密码
去 PDS 换会话,换到了才发 rice 令牌。这里的 8 位下限只是提前挡一道,
真正的规则在 PDS。
