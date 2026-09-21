# VerificationCodeController

发短信 / 邮件验证码。替代 core 的 `/sms/send` 和 `/email/send`。

共通约定见 [README](README.md)。

---

## `POST /api/verification_codes`

匿名可用 —— 注册和找回密码的人本来就没登录。

### 请求

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `channel` | string | 是 | `sms` 或 `email` |
| `purpose` | string | 是 | 见 [README 的 purpose 表](README.md#验证码) |
| `phone` | string | `channel=sms` 时 | 手机号 |
| `phone_region` | string | 否 | 区号,默认 `86` |
| `email` | string | `channel=email` 时 | 邮箱 |

```json
{"channel": "sms", "phone": "13800000000", "purpose": "register"}
```

### 响应

`204`,body 为空。`204` 和 `429` 都返回 `Retry-After` 响应头,值为服务器计算的剩余等待秒数。
客户端用它显示重新发送倒计时;刷新页面或切换用途不会重置服务端限制。

**响应不含验证码**,也不告诉你这个手机号 / 邮箱注册过没有。

### 错误

| 状态码 | 什么时候 |
| --- | --- |
| `422` | `channel` / `purpose` / 目标格式不合法 |
| `429` | 同一个 (channel, target) 60 秒内已经发过,跨用途共享限制,已消费的验证码也计入 |
| `502` | 短信 / 邮件通道发送失败 |
| `503` | 选择的通道未配置 |

---

## 通道

`sms` 走阿里云 Dysmsapi,`email` 走 SMTP(Swoosh)。

生产默认 `RICE_VERIFICATION_MODE=live`：任一通道没配全，该通道返回 `503`，
不会假报发送成功，也不会留下未发送的验证码。另一个已配置通道仍可用。
仅隔离测试显式设为 `log` 时，才使用日志验证码；前端公开选项会标明测试模式。
Semi 不提供假登录的运行时开关，OAuth mock 仅在自动测试内使用。

配置在 `config/runtime.exs`:

```elixir
config :rice, Rice.Notifications.AliyunSms,
  access_key_id: ..., access_key_secret: ...,
  sign_name: ..., template_code: ...

config :rice, Rice.Mailer, adapter: Swoosh.Adapters.SMTP, relay: ..., ...
config :rice, Rice.Notifications.Smtp, sender_name: ..., sender_address: ...
```

阿里云那边四个必填项少一个就算没配好 —— 少一个签名就算不对,发出去是 400。

## 与 core 的差别

core 完全没有频率限制,同一个手机号可以被无限次轰炸;也没有尝试次数上限,
6 位码可以一直猜。这两条在 rice 里都有。
