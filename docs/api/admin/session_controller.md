# Admin.SessionController

管理端登录。替代 core 的 `/admin/login-with-password` +
`/sms/send` + `/admin/login-with-verification-code`。

共通约定见 [../README](../README.md)。

---

## 为什么是两步

core 的流程:`login-with-password` 只回一个 bool,前端再自己去调**公开的**
`/sms/send` 要验证码,最后 `login-with-verification-code` 换令牌。

那个公开的发码接口意味着**不知道密码也能让管理员的手机响**。

rice 把前两步合成一个:密码验过了才发码。

---

## `POST /api/admin/session/challenge`

第一步。匿名可达。

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `phone` | string | 是 | |
| `phone_region` | string | 否 | 默认 `86` |
| `password` | string | 是 | |

### 响应

`202`,body 为空。验证码已发到这个号码上(`purpose=admin_login`)。

### 错误

| 状态码 | body |
| --- | --- |
| `401` | `{"errors":{"detail":"手机号、密码或验证码不正确"}}` |
| `429` | `{"errors":{"detail":"操作过于频繁,请稍后再试"}}` |

密码错、账号不存在、账号被停用返回的都是同一个 `401` —— 区分开就是一个
「这个手机号是不是管理员」的探测器。

---

## `POST /api/admin/session`

第二步。匿名可达。

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `phone` | string | 是 | |
| `phone_region` | string | 否 | 默认 `86` |
| `password` | string | 是 | **要再验一次** |
| `code` | string | 是 | 第一步发的验证码 |

密码要再传一遍:只有验证码不够 —— 那样拿到短信的人就能登进去。

### 响应 `201`

```json
{
  "data": {
    "token": "…",
    "admin": {
      "id": "3ke6kg3wk223e",
      "nickname": "运维小张",
      "email": null,
      "phone": "13900000001",
      "phone_region": "86",
      "role": "admin",
      "superuser": false,
      "avatar": null,
      "last_login_at": "2026-07-29T09:00:00.000000Z",
      "inserted_at": "2026-01-01T00:00:00.000000Z"
    }
  }
}
```

这个 `token` **只能用在 `/api/admin/*`**,调不了 C 端接口;反过来也一样。

### 错误

| 状态码 | body |
| --- | --- |
| `401` | `{"errors":{"detail":"手机号、密码或验证码不正确"}}` |
| `429` | 试错超过 5 次 |

---

## `DELETE /api/admin/session`

登出。需要登录。撤销当前这一把令牌。

响应 `204`。

## 密码摘要

PBKDF2-HMAC-SHA256,27500 轮,64 字节输出,Base64。和 core 的
`PasswordHashGenerator` **逐字节兼容** —— 迁数据时不必强制所有管理员改密码。

只有一处刻意不照抄:core 用 `Random.Shared` 生成盐,那不是密码学安全的随机源。
rice 用 `:crypto.strong_rand_bytes/1`。老密码照样验得过 —— 验证不关心盐当初
是怎么来的。

密码比较用 `:crypto.hash_equals/2` 定长比较。账号不存在时也走一遍同样耗时的
运算,否则「这个账号存不存在」能从响应时间读出来。
