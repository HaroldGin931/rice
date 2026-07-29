# Admin.BadgeController

勋章的后台维护。**登录即可**。

替代 core 的 `/admin/medal/page`、`/medal/add`、`/medal/users-holding/page`。

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

## 给一枚已有的勋章补发持有人

**没有这个接口 —— core 也没有。** 发勋章只能在新建的时候一起发,
建完之后加不了人。

core 的三个勋章接口(`medal/create`、`medal/page`、`medal/users-holding/page`)
都迁过来了,这是 core 本身的形状。要补发的话,写入路径
(`Rice.Community.award_badge/2`)已经就绪,缺的只是一个控制器。
