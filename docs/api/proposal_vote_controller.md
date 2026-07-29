# ProposalVoteController

投票。替代 core 的 `/proposal/vote` 和 `/proposal/my-proposal-choice`。

**两个接口都要登录。**

共通约定见 [README](README.md)。

---

## `GET /api/proposals/:proposal_id/vote`

我在这个提案上投了什么。

### 响应 `200`

```json
{ "data": { "choice": "agree", "inserted_at": "2026-07-29T09:00:00.000000Z" } }
```

没投过时 `data` 是 `null`:

```json
{ "data": null }
```

`404` —— 提案不存在。

---

## `POST /api/proposals/:proposal_id/vote`

投票。

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `choice` | string | 是 | `agree` 或 `oppose` |

### 响应 `201`

```json
{ "data": { "choice": "agree", "inserted_at": "2026-07-29T09:00:00.000000Z" } }
```

### 错误

| 状态码 | body | 什么时候 |
| --- | --- | --- |
| `401` | | 没登录 |
| `404` | | 提案不存在 |
| `422` | `{"errors":{"detail":"投票已结束"}}` | 提案不是 `open`,或已过 `closes_at` |
| `422` | `{"errors":{"choice":["只能是 agree 或 oppose"]}}` | |
| `422` | changeset 错误 | 已经投过了 |

## 一人一票

由 `(proposal_id, user_id)` 上的唯一索引保证 —— 并发的重复投票会被**数据库**
挡下,而不是靠「先查一下有没有投过再插」。后者在两个请求同时到达时会双双通过。

票数 `agree_count` / `oppose_count` 和投票记录在同一个事务里更新。
