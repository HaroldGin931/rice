# BadgeController

某个人的勋章墙。替代 core 的 `/user-medal/page?domainName=…`。

共通约定见 [README](README.md)。

---

## `GET /api/users/:user_id/badges`

`:user_id` 接受四种写法:

| 写法 | 例子 |
| --- | --- |
| `me` | 当前登录用户 —— **只有这个写法需要令牌** |
| rice id | `3ke6kg3wk223e` |
| DID | `did:plc:abc123` |
| handle | `alice.web5.xjdao.xyz` |

**故意不认手机号和邮箱** —— 那样这个公开接口就成了「这个手机号注册过没有」
的探测器。

### 响应 `200`

```json
{
  "data": [
    {
      "id": "3ke6kg3wk223e",
      "name": "首批共建者",
      "image": { "id": "…", "url": "/api/attachments/…", "…": "…" },
      "awarded_at": "2026-07-29T09:00:00.000000Z"
    },
    {
      "id": "3ke6kg3wk1abc",
      "name": "提案达人",
      "image": { "…": "…" },
      "awarded_at": null
    }
  ]
}
```

返回的是**勋章全集**,每一枚带上这个人的 `awarded_at` —— 没获得是 `null`。

勋章墙要把没拿到的也灰着列出来,只返回已获得的就渲染不出来了。不分页。

### 错误

| 状态码 | 什么时候 |
| --- | --- |
| `401` | `:user_id` 是 `me` 但没带令牌 |
| `404` | 这个人不存在 |

后台维护勋章的入口见 [admin/badge_controller](admin/badge_controller.md)。
