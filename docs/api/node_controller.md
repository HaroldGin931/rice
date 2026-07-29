# NodeController

节点与节点成员。替代 core 的 `/node/list` 和 `/user/node-user-list`。

共通约定见 [README](README.md)。

---

## `GET /api/nodes`

公开,不需要登录。不分页,按 `position` 排。

### 响应 `200`

```json
{
  "data": [
    {
      "id": "3ke6kg3wk223e",
      "name": "北京节点",
      "description": "…",
      "position": 0,
      "logo": { "id": "…", "url": "/api/attachments/…", "…": "…" },
      "owner": {
        "id": "…",
        "did": "did:plc:…",
        "handle": "…",
        "nickname": "…",
        "bio": "…",
        "avatar": null,
        "node_member": true,
        "grain_balance": 1200
      }
    }
  ]
}
```

`owner` 是节点主,可以为 `null`。

core 的 `NodeListVo` 把节点主的 did 和稻米数**摊平在顶层**;这里作为嵌套的
用户对象,昵称和头像也就跟着一起来了,不必再存一份副本。

---

## `GET /api/nodes/members`

节点成员名单(`node_member = true` 的用户)。公开,不分页,按 id 升序。

已停用和已注销的用户不在名单里。

### 响应 `200`

```json
{ "data": [ { "id": "…", "did": "…", "handle": "…", "nickname": "…", "avatar": null, "node_member": true } ] }
```

是 `public` 视图 —— 不含手机、邮箱、余额。

谁是节点成员由后台设置,见
[admin/user_controller](admin/user_controller.md)。
