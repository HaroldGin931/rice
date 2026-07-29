# Admin.PasswordController

管理员忘记密码。凭手机验证码重置。

共通约定见 [../README](../README.md)。

---

## `POST /api/admin/passwords/challenge`

发重置码。匿名可达。

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `phone` | string | 是 | |
| `phone_region` | string | 否 | 默认 `86` |

### 响应

`202`,body 为空。

**手机号不是管理员时也返回 `202`** —— 不泄露谁是管理员。这种情况下什么也没发。

### 错误

| 状态码 | body |
| --- | --- |
| `429` | `{"errors":{"detail":"操作过于频繁,请稍后再试"}}` |

---

## `POST /api/admin/passwords`

用码重置密码。匿名可达。

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `phone` | string | 是 | |
| `phone_region` | string | 否 | 默认 `86` |
| `code` | string | 是 | `purpose=admin_reset_password` 的验证码 |
| `password` | string | 是 | 新密码,至少 8 位 |

### 响应

`204`。

成功后**踢掉该管理员的全部会话** —— 密码泄露之后改密码,得把别人手上那把
钥匙也一起作废。

### 错误

| 状态码 | body |
| --- | --- |
| `422` | `{"errors":{"code":["验证码不正确"]}}` —— 码错**或**这个号不是管理员 |
| `422` | `{"errors":{"password":["密码至少 8 位"]}}` |
| `429` | `{"errors":{"detail":"尝试次数过多,请重新获取验证码"}}` |

## 只走手机号

管理端的登录和找回密码**都只认手机号**。邮箱只是联系方式,没有对应的入口 ——
所以建管理员时手机号是必填的,见
[admin_user_controller](admin_user_controller.md#post-apiadminadmin_users)。
