# PasswordController

凭验证码重置密码。替代 core 的 `/user/reset-password`。

共通约定见 [README](README.md)。

---

## `POST /api/passwords/reset`

**匿名可用** —— 忘了密码的人本来就登不进来。身份由验证码证明:码发到已登记的
手机 / 邮箱,能收到就说明是本人。

### 请求

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `channel` | string | 是 | `sms` 或 `email` |
| `code` | string | 是 | `purpose=reset_password` 的验证码 |
| `password` | string | 是 | 新密码,至少 8 位 |
| `phone` | string | `channel=sms` 时 | |
| `phone_region` | string | 否 | 默认 `86` |
| `email` | string | `channel=email` 时 | |

### 响应

`204`,body 为空。

密码改在 **PDS** 上(`com.atproto.admin.updateAccountPassword`),rice 库里
本来就没有密码。

### 错误

| 状态码 | body | 什么时候 |
| --- | --- | --- |
| `422` | `{"errors":{"code":["验证码不正确"]}}` | 码错**或**这个联系方式没有对应用户 |
| `422` | `{"errors":{"code":["验证码已过期"]}}` | |
| `422` | `{"errors":{"password":["密码至少 8 位"]}}` | |
| `429` | `{"errors":{"detail":"尝试次数过多,请重新获取验证码"}}` | 试错超过 5 次 |
| `502` | `{"errors":{"detail":"重置密码失败"}}` | PDS 不可用 |

「用户不存在」和「验证码不正确」返回的是同一个东西。区分了,这就成了一个
「这个手机号注册过没有」的探测接口。

## 改密码之后

重置成功会**撤销该用户的全部 rice 令牌**。密码泄露之后改密码,得把别人手上
那把钥匙也一起作废才有意义。
