# AnnouncementController

公告。替代 core 的 `/information/page` 和 `/information/detail`。

共通约定见 [README](README.md)。

---

## `GET /api/announcements`

公开,不需要登录。分页,新的在前。

| 参数 | 说明 |
| --- | --- |
| `limit` `before` `after` | 见 [分页](README.md#分页) |

### 响应 `200`

```json
{
  "data": [
    {
      "id": "3ke6kg3wk223e",
      "title": "关于 2026 年度……",
      "position": 0,
      "attachment": { "id": "…", "url": "/api/attachments/…", "content_type": "text/html", "…": "…" },
      "inserted_at": "2026-07-29T09:00:00.000000Z"
    }
  ],
  "meta": { "next_cursor": "3ke6kg3wk1xyz" }
}
```

公告正文是一个 **html 附件**,不是数据库里的一个字段 —— core 也是这么存的。
前端拿 `attachment.url` 去取,默认内联返回。

---

## `GET /api/announcements/:id`

单条公告。响应 `200`,`data` 是上面的单个对象。

| 状态码 | 什么时候 |
| --- | --- |
| `404` | id 不存在,或格式就不合法 |

后台维护的入口见 [admin/catalog_controller](admin/catalog_controller.md)。
