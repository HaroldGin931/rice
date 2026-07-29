# Admin.ProposalController

提案审核。**登录即可**。

替代 core 的 `/admin/proposal/page`、`/detail`、`/take-off`、
`/delete-comment`。

共通约定见 [../README](../README.md)。

---

## 后台提案对象

比 C 端那份多了 `listed` 和 `deleted_at`,少了 `my_vote`(后台没有「我的票」
这个视角)。

```json
{
  "id": "3ke6kg3wk223e",
  "title": "关于设立乡建基金的提案",
  "status": "open",
  "listed": true,
  "closes_at": "2026-08-15T00:00:00.000000Z",
  "agree_count": 42,
  "oppose_count": 8,
  "total_votes": 50,
  "attachment": { "…": "…" },
  "author": { "…": "…" },
  "deleted_at": null,
  "inserted_at": "2026-07-29T09:00:00.000000Z"
}
```

---

## `GET /api/admin/proposals`

分页,新的在前。

| 参数 | 说明 |
| --- | --- |
| `status` | `open` / `passed` / `rejected` |
| `listed` | `true` / `false` |
| `q` | 按标题模糊搜 |
| `limit` `before` `after` | 见 [分页](../README.md#分页) |

**这份列表看得到已下架和已软删的提案。** C 端那份看不到。

core 的后台列表和 C 端用的是同一个「只看上架」的查询 —— 下架之后后台自己也
找不回来,没法复核。

---

## `GET /api/admin/proposals/:id`

单条提案,**带前 100 条评论**。

### 响应 `200`

```json
{
  "data": {
    "…后台提案对象…",
    "comments": [
      { "id": "…", "body": "…", "author": { "…": "…" }, "inserted_at": "…" }
    ]
  }
}
```

`404` —— 不存在或 id 格式不合法(已下架的**能**查到)。

---

## `PATCH /api/admin/proposals/:id`

下架 / 恢复。

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `listed` | boolean | 是 | `false` 下架,`true` 恢复 |

core 的 `take-off` 只能**单向**下架,没有恢复的入口。

### 响应 `200`

`data` 是更新后的后台提案对象,`comments` 为空数组。

| 状态码 | body |
| --- | --- |
| `404` | 提案不存在 |
| `422` | `{"errors":{"detail":"listed 必须是 true 或 false"}}` |

---

## `DELETE /api/admin/proposals/:proposal_id/comments/:id`

删**任意**评论(软删)。C 端只能删自己的。

响应 `204`。

`404` —— 提案或评论不存在。
