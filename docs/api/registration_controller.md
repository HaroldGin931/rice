# RegistrationController

注册。替代 core 的 `/user/pre-register` + `/user/register`。

两步:先用验证码换一张**注册票**,再凭票 + 用户名前缀 + 密码开户。

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
| `username` | string | 是 | 用户名前缀，去除首尾空白并转小写后 3–18 位；只允许英文字母、数字、连字符，首尾须为字母或数字 |
| `password` | string | 是 | 至少 8 位 |

联系方式从票里取,**不从请求体取**。服务端使用当前 PDS 客户端的 `handle_domain()`
将前缀拼成 `<username>.<PDS_HANDLE_DOMAIN>`；客户端传入完整 `handle` 或域名不生效，
不再自动分配用户名前缀。3–18 位是当前 PDS 服务子域约束；域名来自服务器配置。
用户名是否可用以 PDS 建号结果为准，占用时可更换前缀后使用同一有效票据重试。
Rice 昵称与 PDS 公开资料昵称初始化为该前缀，可之后在个人资料中修改；注册请求的
`nickname` 不生效。资料初始化失败不阻止已创建账号登录。

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
| `422` | `{"errors":{"detail":"用户名须为 3–18 位字母、数字或连字符，首尾须为字母或数字"}}` | 前缀缺失、类型错误、长度或格式不符 |
| `422` | `{"errors":{"detail":"用户名已被使用，请换一个用户名"}}` | PDS 返回 `HandleNotAvailable` |
| `422` | `{"errors":{"detail":"密码至少 8 位"}}` | |
| `422` | `{"errors":{"detail":"该手机号或邮箱已被使用"}}` | |
| `502` | `{"errors":{"detail":"创建账号失败"}}` | PDS 建号失败或不可用 |

## 密码归谁管

**密码的权威在 PDS**,rice 不存密码,也不存摘要。登录是拿 handle + 密码
去 PDS 换会话,换到了才发 rice 令牌。这里的 8 位下限只是提前挡一道,
真正的规则在 PDS。
