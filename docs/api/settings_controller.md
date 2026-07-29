# SettingsController

基金会公开信息。替代 core 的 `/global-config/detail` 的公开部分。

共通约定见 [README](README.md)。

---

## `GET /api/settings/foundation`

公开,不需要登录。

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

| 字段 | 说明 |
| --- | --- |
| `fund_scale` | 基金规模 |
| `issued_grain_scale` | 已发行稻米规模 |
| `proposal_approval_votes` | 提案通过所需票数 |
| `documents` | 章程一类的公开文档,附件数组,按位置排 |

全站只有一行配置。后台改的入口见
[admin/settings_controller](admin/settings_controller.md)。
