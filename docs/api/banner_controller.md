# BannerController

首页轮播位。替代 core 的 `/banner/list`。

共通约定见 [README](README.md)。

---

## `GET /api/banners`

公开,不需要登录。不分页,按 `position` 排。

### 响应 `200`

```json
{
  "data": [
    {
      "id": "3ke6kg3wk223e",
      "url": "https://…",
      "position": 0,
      "image": { "id": "…", "url": "/api/attachments/…", "…": "…" }
    }
  ]
}
```

`url` 是点击后跳转的目标,可以为空;`image` 是图片附件,见
[attachment_controller](attachment_controller.md#附件对象)。

后台维护的入口见 [admin/catalog_controller](admin/catalog_controller.md)。
