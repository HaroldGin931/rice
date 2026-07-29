# ProposalCommentController

提案评论。替代 core 的 `/proposal/comment` 和 `/proposal/delete-my-comment`。

列表公开可读,写和删要登录。

共通约定见 [README](README.md)。

---

## 评论对象

```json
{
  "id": "3ke6kg3wk223e",
  "body": "支持,建议补充资金用途的说明。",
  "author": { "id": "…", "did": "…", "handle": "…", "nickname": "…", "avatar": null, "node_member": false },
  "inserted_at": "2026-07-29T09:00:00.000000Z"
}
```

> core 在评论表上存了一份 `user_name` 副本 —— 改了昵称,老评论上还是旧名字。
> 这里 join 用户表。

---

## `GET /api/proposals/:proposal_id/comments`

公开。分页,新的在前。

| 参数 | 说明 |
| --- | --- |
| `limit` `before` `after` | 见 [分页](README.md#分页) |

响应 `200`,`data` 是评论对象数组。已软删的不在里面。

`404` —— 提案不存在。

---

## `POST /api/proposals/:proposal_id/comments`

发评论。**需要登录。**

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `body` | string | 是 | 1–512 字,首尾空白会被去掉 |

响应 `201`,`data` 是评论对象。

| 状态码 | 什么时候 |
| --- | --- |
| `401` | 没登录 |
| `404` | 提案不存在 |
| `422` | 正文为空或超长 |

---

## `DELETE /api/proposals/:proposal_id/comments/:id`

删**自己的**评论(软删)。**需要登录。**

响应 `204`。

| 状态码 | 什么时候 |
| --- | --- |
| `403` | 这不是你的评论 |
| `404` | 提案或评论不存在 |

后台能删任意评论,见
[admin/proposal_controller](admin/proposal_controller.md#delete-apiadminproposalsproposal_idcommentsid)。
