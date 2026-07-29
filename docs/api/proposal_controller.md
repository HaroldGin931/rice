# ProposalController

提案。替代 core 的 `/proposal/*` 一组接口。

列表和详情**公开可读**,带令牌时多一个 `my_vote` 字段。写操作要登录。

共通约定见 [README](README.md)。

---

## 提案对象

```json
{
  "id": "3ke6kg3wk223e",
  "title": "关于设立乡建基金的提案",
  "status": "open",
  "closes_at": "2026-08-15T00:00:00.000000Z",
  "agree_count": 42,
  "oppose_count": 8,
  "total_votes": 50,
  "my_vote": "agree",
  "attachment": { "id": "…", "url": "/api/attachments/…", "…": "…" },
  "author": { "id": "…", "did": "…", "handle": "…", "nickname": "…", "avatar": null, "node_member": false },
  "inserted_at": "2026-07-29T09:00:00.000000Z"
}
```

| 字段 | 说明 |
| --- | --- |
| `status` | `open` / `passed` / `rejected` |
| `total_votes` | 现算的,不是另存一列 —— 不会出现三份数不一致 |
| `my_vote` | 当前用户投的 `agree` / `oppose`;未登录或没投过是 `null` |
| `attachment` | 提案正文,一个附件 |

> core 把「我投了没」塞在列表 VO 的 `choice` 里,用 `0` 表示没投。
> 这里用 `null`,和「投了但值是 0」区分得开。

---

## `GET /api/proposals`

公开。分页,新的在前。

| 参数 | 说明 |
| --- | --- |
| `status` | `open` / `passed` / `rejected` |
| `user_id` | 只看某个人发起的(rice id) |
| `mine` | **需要令牌**。见下 |
| `limit` `before` `after` | 见 [分页](README.md#分页) |

`mine` 决定「和我的关系」:

| 值 | 含义 |
| --- | --- |
| `created` / `1` / `true` | 我发起的 |
| `voted` | 我投过票的 |
| `all` | 前两者的并集 |

没带令牌时 `mine` 被忽略,退回全站列表。

> core 那边是 `/proposal/my-proposal-list` 的数字 `type`(0/1/2)。
>
> 「我投过票的」用 `EXISTS` 子查询而不是 join —— join 会让投过多次的提案
> 重复出现,再靠 `distinct` 去重又会和游标分页的 `order_by` 打架。

列表**看不到已下架和已软删的**。后台那份看得到,见
[admin/proposal_controller](admin/proposal_controller.md)。

### 响应 `200`

```json
{ "data": [ …提案对象… ], "meta": { "next_cursor": "…" } }
```

---

## `GET /api/proposals/:id`

单条提案。公开。响应 `200`,`data` 是提案对象。

`404` —— 不存在、已下架、或 id 格式不合法。

---

## `POST /api/proposals`

发起提案。**需要登录。**

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `title` | string | 是 | 1–128 字 |
| `closes_at` | string | 是 | ISO 8601,**必须是将来** |
| `attachment_id` | string | 否 | 提案正文附件 |

响应 `201`,`data` 是提案对象。校验失败 `422`。

---

## `DELETE /api/proposals/:id`

删自己的提案(软删)。**需要登录。**

响应 `204`。

| 状态码 | 什么时候 |
| --- | --- |
| `403` | 这不是你的提案 —— 不假装成功 |
| `404` | 提案不存在,**或已被后台下架** |

C 端的所有提案接口(详情、删除、投票、评论)走的都是同一个「只看上架的」查询。
下架之后作者自己也操作不了 —— 这是有意的。后台那份看得到,见
[admin/proposal_controller](admin/proposal_controller.md)。

投票见 [proposal_vote_controller](proposal_vote_controller.md),
评论见 [proposal_comment_controller](proposal_comment_controller.md)。
