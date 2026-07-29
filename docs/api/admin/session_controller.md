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

### 密码试错有上限

这个接口密码对了 `202`、错了 `401` —— 这是一个可以无限次问的「密码对不对」。
所以**连错 5 次锁 15 分钟**,锁定期间即使密码对了也返回 `429`。密码一旦对上
就立刻清零,手滑几次不会攒着。

计数键是**手机号本身**,存不存在这个管理员都记。只给存在的记的话,
第六次还返回 `401` 就等于告诉对方「这个号不是管理员」——
正好把上面那条设计抵消掉。

代价说明白:知道某个管理员手机号的人,连错 5 次就能把他挡在门外 15 分钟。
这是账号锁定类方案共有的问题。选 15 分钟而不是永久锁,是因为永久锁意味着
任何人都能让一个管理员**永远**登不进去,那比暴力破解更糟。
要把这个代价也去掉,得按调用方维度(IP 之类)限流,那需要一层现在还没有的基础设施。

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
