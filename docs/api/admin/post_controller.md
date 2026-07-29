# Admin.PostController

贴文下架 / 恢复。**登录即可**。

替代 core 的 `/admin/post/take-off-post`。

共通约定见 [../README](../README.md)。

---

## 这是一层代理

**贴文不在 rice 的库里** —— 它属于 post 服务(`/api/posts/*`)。下架的做法是
给贴文打一个 `blacklist` 标签,恢复就是把标签清空。

rice 这层存在的意义是**把管理凭据留在服务端**:否则前端得自己持有 post 服务的
admin token。

贴文列表本身管理端是直连 post 服务的,不经过 rice,也不经过 core。

---

## `POST /api/admin/post_takedowns`

下架。

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `uri` | string | 是 | 贴文的 AT URI |

```json
{ "uri": "at://did:plc:abc123/app.bsky.feed.post/3ke6kg3wk223e" }
```

`uri` 放在 body 里而不是路径上 —— **AT URI 里有斜杠**,塞进路径要转义两遍。

响应 `204`。

---

## `DELETE /api/admin/post_takedowns`

恢复。同样在 body 里传 `uri`。

响应 `204`。

core 的 `take-off-post` 只能**单向**下架,没有恢复的入口。

---

## 错误

| 状态码 | body | 什么时候 |
| --- | --- | --- |
| `401` | | 没令牌 |
| `422` | `{"errors":{"uri":["缺少贴文 uri"]}}` | `uri` 没传或是空串 |
| `502` | `{"errors":{"detail":"贴文服务返回错误: …"}}` | post 服务返回非 2xx,或连不上 |
| `503` | `{"errors":{"detail":"贴文服务未配置"}}` | 没配 `base_url` 或 `admin_token` |

配置:

```elixir
config :rice, :post_service, base_url: "https://…", admin_token: "…"
```
