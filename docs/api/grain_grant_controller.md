# GrainGrantController

全站发放记录(公开)。替代 core 的 `/score-distribute-record/page`。

共通约定见 [README](README.md)。

---

## `GET /api/grain_grants`

公开,不需要登录。分页,新的在前。

只列 `kind = "grant"` 的记录 —— 也就是后台往外发的那些,不含用户之间的转赠。

| 参数 | 说明 |
| --- | --- |
| `limit` `before` `after` | 见 [分页](README.md#分页) |

### 响应 `200`

```json
{
  "data": [
    {
      "id": "3ke6kg3wk223e",
      "kind": "grant",
      "amount": 100,
      "memo": "补贴",
      "subject_uri": null,
      "from": null,
      "to": { "id": "…", "did": "…", "handle": "…", "nickname": "…", "avatar": null, "node_member": false },
      "direction": null,
      "inserted_at": "2026-07-29T09:00:00.000000Z"
    }
  ],
  "meta": { "next_cursor": "3ke6kg3wk1xyz" }
}
```

发放没有付款人,所以 `from` 是 `null`。

`direction` 在这个公开列表里恒为 `null` —— 没有「当前用户」这个视角。
自己的明细看 [grain_transfer_controller](grain_transfer_controller.md)。

`to` 是 `public` 视图,**不含手机和邮箱**。后台那份
([admin/grain_controller](admin/grain_controller.md))才带联系方式。
