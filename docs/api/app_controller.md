# AppController

应用入口。替代 core 的 `/app/list`。

共通约定见 [README](README.md)。

---

## `GET /api/apps`

公开,不需要登录。

不分页 —— 按 `position` 排的内容位,一次全给。

### 响应 `200`

```json
{
  "data": [
    {
      "id": "3ke6kg3wk223e",
      "name": "乡建学堂",
      "description": "…",
      "url": "https://…",
      "position": 0,
      "logo": { "id": "…", "url": "/api/attachments/…", "…": "…" }
    }
  ]
}
```

`logo` 是附件对象或 `null`,见 [attachment_controller](attachment_controller.md#附件对象)。

后台维护的入口见 [admin/catalog_controller](admin/catalog_controller.md)。
