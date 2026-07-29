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

新建勋章。

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `name` | string | 是 | 最长 64 |
| `image_id` | string | 否 | 图片附件 id |

响应 `201`,`data` 是勋章对象(`holder_count` 为 `null`)。

`422` —— 名字为空或超长。

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

## 发放勋章

**没有发放接口 —— core 也没有。** core 的管理端只有这三个勋章接口
(`medal/create`、`medal/page`、`medal/users-holding/page`),三个都迁过来了。
勋章数据是直接写库的。

奇怪的是 core 的 `/admin/template/get` 返回了一个「勋章发放」的 Excel 模板
(rice 照迁,见 [template_controller](template_controller.md)),但两边都没有
消费这个模板的接口。要做批量发放的话,写入路径(`Rice.Community` 的
`BadgeAward`)已经就绪,缺的只是一个控制器。
