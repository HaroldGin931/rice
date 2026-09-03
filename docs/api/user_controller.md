# UserController

当前用户的档案。替代 core 的 `/user/login-user-detail` 和 `/user/edit-profile`。

**全部接口都要登录。**

共通约定见 [README](README.md)。

---

## 用户对象

自己看自己 —— 含联系方式:

```json
{
  "id": "3ke6kg3wk223e",
  "did": "did:plc:abc123",
  "handle": "alice.web5.xjdao.xyz",
  "nickname": "爱丽丝",
  "bio": "…",
  "avatar": { "id": "…", "url": "/api/attachments/…", "…": "…" },
  "grain_balance": 1200,
  "grain_frozen_balance": 80,
  "node_member": false,
  "can_publish_tasks": false,
  "email": "alice@example.com",
  "phone": "13800000000",
  "phone_region": "86",
  "inserted_at": "2026-07-29T09:00:00.000000Z"
}
```

别处出现的**别人**的用户对象是 `public` 视图 —— 少了 `email` / `phone` /
`phone_region` / `grain_balance` / `grain_frozen_balance`。联系方式和余额不外露。

`grain_balance` 是可用稻米，`grain_frozen_balance` 是已为任务奖励冻结、尚未结算或
退回的稻米。

`can_publish_tasks` 是服务端管理的任务发布权限，只出现在用户自己的档案和后台用户
对象中。普通用户默认是 `false`，不能通过 `PATCH /api/users/me` 自行开启。

`avatar` 是附件对象或 `null`,形状见 [attachment_controller](attachment_controller.md#附件对象)。

---

## `GET /api/users/me`

当前登录用户。

响应 `200`,`data` 是上面的用户对象。

---

## `PATCH /api/users/me`

改档案。

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `nickname` | string | 最长 64 |
| `bio` | string | 最长 512 |
| `avatar_id` | string | 附件 id |

只改传了的字段。改不了联系方式(那要验证码,见下面两个接口),也改不了
`handle` / `did` / `grain_balance` / `grain_frozen_balance`。

响应 `200`,`data` 是更新后的用户对象。校验失败 `422`。

---

## `PUT /api/users/me/phone`

改绑手机。**验证码发到新号码上** —— 证明新号码是你的。

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `phone` | string | 是 | 新号码 |
| `phone_region` | string | 否 | 默认 `86` |
| `code` | string | 是 | 新号码上收到的 `modify_phone` 验证码 |

响应 `200`,`data` 是更新后的用户对象。

| 状态码 | body |
| --- | --- |
| `422` | `{"errors":{"code":["验证码不正确"]}}` / `["验证码已过期"]` |
| `422` | 号码已被别的账号占用(changeset 错误) |
| `429` | 试错超过 5 次 |

---

## `PUT /api/users/me/email`

改绑邮箱。同上,`code` 是 `modify_email` 的码,发到新邮箱。

| 字段 | 类型 | 必填 |
| --- | --- | --- |
| `email` | string | 是 |
| `code` | string | 是 |

---

## `DELETE /api/users/me`

注销账号。软删 + 撤销全部令牌。

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `channel` | string | 是 | `sms` 或 `email` —— 用哪个已绑的联系方式确认 |
| `code` | string | 是 | `purpose=delete_account` 的验证码 |

响应 `204`。

| 状态码 | body | 什么时候 |
| --- | --- | --- |
| `422` | `{"errors":{"channel":["账号没有绑定这个联系方式"]}}` | 拿邮箱注销一个只绑了手机的号 |
| `422` | `{"errors":{"code":[…]}}` | 码不对或过期 |
| `429` | | 试错超过 5 次 |

软删的行留在库里 —— 提案、评论、转账记录的外键要指得到。但任何查询都看不见
这个用户。

## 头像的一个已知缺口

改档案时头像**不会**镜像回 PDS 的 profile。PDS 那边要的是 blob 引用,
rice 这边是附件 id,两者不能直接互换。见
[`../backend-migration-plan.md`](../backend-migration-plan.md) 的遗留项。
