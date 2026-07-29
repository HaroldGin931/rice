# Admin.UserController

后台用户管理。**登录即可**(运营也能用)。

替代 core 的 9 个接口:

| core | rice |
| --- | --- |
| `user/page`、`node-user/page`、`user/search`、`search-by-name`、`unbound-node-user-search` | `GET /users` 一个带过滤的列表 |
| `user/detail` | `GET /users/:id` |
| `enable`、`disable`、`set-node-user`、`cancel-node-user` | `PATCH /users/:id` —— 同一行上的两个布尔位 |

共通约定见 [../README](../README.md)。

---

## 后台用户对象

比 C 端的 `public` 视图多了联系方式、余额和停用状态 —— 后台就是靠这些找人的。

```json
{
  "id": "3ke6kg3wk223e",
  "did": "did:plc:abc123",
  "handle": "alice.web5.xjdao.xyz",
  "nickname": "爱丽丝",
  "bio": "…",
  "avatar": null,
  "grain_balance": 1200,
  "node_member": false,
  "email": "alice@example.com",
  "phone": "13800000000",
  "phone_region": "86",
  "disabled": false,
  "disabled_at": null,
  "inserted_at": "2026-07-29T09:00:00.000000Z"
}
```

---

## `GET /api/admin/users`

分页,新的在前。已软删(注销)的用户不在里面。

| 参数 | 说明 |
| --- | --- |
| `q` | 模糊搜:昵称 / handle / DID / 邮箱 / 手机号 |
| `node_member` | `true` / `false` |
| `disabled` | `true` / `false` |
| `limit` `before` `after` | 见 [分页](../README.md#分页) |

组合起来就覆盖了 core 那五个列表接口:节点成员列表是
`?node_member=true`,「未绑定节点的用户搜索」是 `?q=…&node_member=false`。

### 搜索里的 `%`

`q` 会进 `ILIKE`,所以 `%` `_` `\` 都做了转义。core 把运营输入直接拼进
`ILIKE`,一个 `%` 就是整表扫描。

### 响应 `200`

```json
{ "data": [ …后台用户对象… ], "meta": { "next_cursor": "…" } }
```

---

## `GET /api/admin/users/:id`

单个用户。响应 `200`,`data` 是后台用户对象。

`404` —— 不存在、已注销,或 id 格式不合法。

---

## `PATCH /api/admin/users/:id`

改用户的两个管理位。

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `disabled` | boolean | `true` 停用,`false` 恢复 |
| `node_member` | boolean | 是否节点成员 |

只接受这两个字段,其余一律忽略。两个都没传是 `422`。

### 停用会立刻生效

停用时在**同一个事务**里撤销该用户的全部令牌。

core 只改一个标记 —— 用户手上的 daoJwt 还能用满 30 天,等于「禁用」要等一个月
才生效。

### 响应 `200`

`data` 是更新后的后台用户对象。

| 状态码 | body |
| --- | --- |
| `404` | 用户不存在 |
| `422` | `{"errors":{"detail":"没有可改的字段(只接受 disabled / node_member)"}}` |

某个用户的稻米明细见
[grain_controller](grain_controller.md#get-apiadminusersuser_idgrain_transfers)。
