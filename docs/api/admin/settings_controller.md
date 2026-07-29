# Admin.SettingsController

全站配置。**登录即可**。

替代 core 的 `/admin/global-config/detail` +
`/modify-foundation-info` + `/modify-proposal-config` —— 三个接口改的却是
**同一行**。这里是 `GET` 和 `PATCH` 各一个。

共通约定见 [../README](../README.md)。

---

## `GET /api/admin/settings`

### 响应 `200`

```json
{
  "data": {
    "fund_scale": 1000000,
    "issued_grain_scale": 250000,
    "proposal_approval_votes": 100,
    "documents": [
      { "id": "…", "filename": "章程.pdf", "url": "/api/attachments/…", "…": "…" }
    ]
  }
}
```

和公开的 [`GET /api/settings/foundation`](../settings_controller.md) 同形 ——
这份配置本来就是公开信息,后台看到的没有更多。

---

## `PATCH /api/admin/settings`

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `fund_scale` | integer | 基金规模,≥ 0 |
| `issued_grain_scale` | integer | 已发行稻米规模,≥ 0 |
| `proposal_approval_votes` | integer | 提案通过所需票数,≥ 0 |
| `document_ids` | string[] | 公开文档的附件 id 数组,**顺序即展示顺序** |

只改传了的字段。其余字段一律忽略,不会被当成配置写进去。

### `document_ids` 是整份替换

传了这个字段就是**整份覆盖**:先清空原有关联,再按数组顺序重建。
传空数组等于清空文档列表。不传则完全不动。

整件事在一个事务里 —— 不会留下清空了却没重建的中间状态。

### 响应 `200`

`data` 是更新后的配置(和 `GET` 同形)。

| 状态码 | 什么时候 |
| --- | --- |
| `422` | 数值为负,或 `document_ids` 里有不存在的附件 id |

全站只有一行配置。没有的话第一次 `PATCH` 会建出来。
