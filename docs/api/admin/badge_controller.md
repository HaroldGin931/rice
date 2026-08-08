# Admin.BadgeController

勋章的后台维护。**登录即可**。

替代 core 的 `/admin/medal/page`、`/medal/create`、`/medal/users-holding/page`,
外加一个 core 没有的:[给已有勋章补发持有人](#post-apiadminbadgesbadge_idholders)。

共通约定见 [../README](../README.md)。

---

## `GET /api/admin/badges`

勋章列表。分页,新的在前。

| 参数 | 说明 |
| --- | --- |
| `page` `per_page` | 后台表格用页码,见 [分页](../README.md#页码传-page-时) |
| `limit` `before` `after` | 也支持游标,见 [分页](../README.md#分页) |

### 响应 `200`

```json
{
  "data": [
    {
      "id": "3ke6kg3wk223e",
      "name": "首批共建者",
      "image": { "id": "…", "url": "/api/attachments/…", "…": "…" },
      "holder_count": 128,
      "inserted_at": "2026-07-29T09:00:00.000000Z"
    }
  ],
  "meta": { "next_cursor": "…" }
}
```

`holder_count` 是**现算的**。core 把它缓存在 `t_medal.quantity` 上,
发完勋章忘了更新那一列,数就永远对不上了。

---

## `POST /api/admin/badges`

新建勋章,可以顺带发给一批人。

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `name` | string | 是 | 最长 64 |
| `image_id` | string | 否 | 图片附件 id |
| `to` | string[] | 否 | 首批持有人:手机号 / 邮箱 / handle / DID / id |

`to` 的写法和[发放稻米](grain_controller.md#收款人怎么写)完全一致 ——
运营在两个界面里粘的是同一份名单。重复的只算一次,空字符串丢掉,
停用和已注销的用户认不出来。

### 建和发在一个事务里

core 的 `medal/create` 收一个名单**文件**,建勋章和发勋章是同一次调用。这里收数组
(解析 Excel 是前端的事),但语义一样:**名单里有一个人认不出来,勋章也不建**。

分两步的话,名单里一个笔误就会留下一枚没有持有人的孤儿勋章 ——
而名单恰恰是最容易出错的地方。

### 响应 `201`

`data` 是勋章对象(`holder_count` 为 `null`)。

### 错误

| 状态码 | body |
| --- | --- |
| `422` | `{"errors":{"name":["不能为空"]}}` |
| `422` | `{"errors":{"to":["这些用户不存在: 13800000000"]}}` |
| `422` | `{"errors":{"to":["名单里必须是字符串,这些不是: nil"]}}` |

---

## `GET /api/admin/badges/:badge_id/holders`

持有这枚勋章的人。分页。

| 参数 | 说明 |
| --- | --- |
| `q` | 按持有人模糊搜 |
| `page` `per_page` | 后台表格用页码,见 [分页](../README.md#页码传-page-时) |
| `limit` `before` `after` | 也支持游标,见 [分页](../README.md#分页) |

`q` 里的 `%` `_` 做了转义。

### 响应 `200`

```json
{
  "data": [
    {
      "id": "…", "did": "…", "handle": "…", "nickname": "爱丽丝",
      "bio": "…", "avatar": null, "node_member": false,
      "email": "alice@example.com",
      "phone": "13800000000",
      "awarded_at": "2026-07-29T09:00:00.000000Z"
    }
  ],
  "meta": { "next_cursor": "…" }
}
```

后台这份**带联系方式**。C 端的勋章墙
([badge_controller](../badge_controller.md))是反过来的视角 ——
某个人的全部勋章。

`404` —— 勋章不存在。

---

## `POST /api/admin/badges/:badge_id/holders`

给一枚**已有**的勋章补发持有人。**core 没有这个接口** —— 那边发勋章只能在
`medal/create` 里跟着新建一起发,建完就加不了人,漏了谁只能重建一枚同名的,
而那会把先拿到的人的获得时间一起改掉。

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `to` | string[] | 是 | 手机号 / 邮箱 / handle / DID / id |

`to` 的写法和[新建勋章](#post-apiadminbadges)、[发放稻米](grain_controller.md#收款人怎么写)
完全一致 —— 运营在这几个界面里粘的是同一份名单。

### 已经持有的人不算错

和新建时一样,**名单里有人认不出来就整批不发**。但和新建不一样的是:名单里
已经持有这枚勋章的人只是被跳过,不是错误。补名单时运营粘的常常是完整名单而不是
差集,重叠是常态而不是笔误 —— 报错的话这个接口就没法用了。

已持有的人**获得时间不会被改**。写入是一条带 `ON CONFLICT DO NOTHING` 的
`INSERT`,所以"已持有"和"两个运营同时点了提交"走的是同一条路:数据库的
唯一索引说了算,不靠先查后写那个会漏的窗口。

### 响应 `201`

```json
{ "data": { "awarded": 12, "already_held": 3 } }
```

| 字段 | 说明 |
| --- | --- |
| `awarded` | 这次真正新发出去的人数 |
| `already_held` | 名单里已经持有的人数(去重之后) |

### 错误

| 状态码 | body | 什么时候 |
| --- | --- | --- |
| `404` | | 勋章不存在 |
| `422` | `{"errors":{"to":["名单不能为空"]}}` | `to` 缺失、是空数组、或者全是空白串 |
| `422` | `{"errors":{"to":["这些用户不存在: 13800000000"]}}` | |
| `422` | `{"errors":{"to":["名单里必须是字符串,这些不是: nil"]}}` | |

空名单在[新建](#post-apiadminbadges)时是合法的(建一枚先放着的空勋章),
在这里不是 —— 补发一个空名单是笔误,不该静悄悄地返回成功。

### 没有对应的撤销接口

发出去的勋章收不回来,core 也没有这个能力。真要撤,现在只能动库。
