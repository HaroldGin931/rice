# Admin.GrainController

后台发放稻米与查明细。**登录即可**。

替代 core 的 `/admin/score/score-distribution`(单发)、
`/score-distribution-batch`(批量)、`/score-distribute-record/page`、
`/user-sore-record-page`。

共通约定见 [../README](../README.md)。

---

## `POST /api/admin/grain_grants`

发放。core 的 single / batch 在这里是**同一个接口** —— 收款人永远是个数组,
发一个人就是长度为 1。

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `to` | string[] | 是 | 收款人标识数组 |
| `amount` | integer | 是 | 正整数,每人各发这么多 |
| `memo` | string | 否 | 留言 |

```json
{ "to": ["13800000000", "alice@example.com", "bob.web5.xjdao.xyz"], "amount": 100, "memo": "补贴" }
```

### 收款人怎么写

数组里每一项可以是:手机号、邮箱、handle、DID 或 rice id。混着写没关系。

- 重复的只发一次
- 空字符串直接丢掉 —— 从表格里粘一列手机号,末尾常带几个空行
- 停用和已注销的用户认不出来(按「不存在」处理)

### 全有或全无

**任何一个收款人解析不出来,整批都不发。** 一整批在一个事务里完成。

core 也是这个语义(数量对不上就抛异常),但它是在拿到分布式锁**之后**才发现的。

### 响应 `201`

```json
{ "data": { "granted": 3 } }
```

`granted` 是去重后实际到账的人数。

### 错误

| 状态码 | body |
| --- | --- |
| `422` | `{"errors":{"to":["这些收款人不存在: 13800000000, x@y.com"]}}` |
| `422` | `{"errors":{"to":["收款人必须是字符串,这些不是: nil, 123"]}}` |
| `422` | `{"errors":{"to":["至少要有一个收款人"]}}` |
| `422` | `{"errors":{"detail":"金额必须是正整数"}}` |

`to` 是 JSON 数组,里面塞什么都能过 HTTP 那一层,所以类型先卡一道 ——
否则一个 `null` 就是 500 而不是 422。

### Excel 批量

core 的 batch 收一个上传文件的 `fileId`,由服务端去解析表格。这里**解析 Excel
是前端的事** —— 服务端不该为了一个功能长出一个表格解析器。模板下载见
[template_controller](template_controller.md)。

---

## `GET /api/admin/grain_grants`

发放记录。分页,新的在前。

| 参数 | 说明 |
| --- | --- |
| `q` | 按收款人模糊搜:昵称 / 邮箱 / 手机号 / handle |
| `since` | ISO 8601,起始时间 |
| `until` | ISO 8601,结束时间 |
| `page` `per_page` | 后台表格用页码,见 [分页](../README.md#页码传-page-时) |
| `limit` `before` `after` | 也支持游标,见 [分页](../README.md#分页) |

`since` / `until` 解析不了就**当没传** —— 一个手滑的日期不该让整个列表 500。

`q` 里的 `%` `_` 做了转义。

### 响应 `200`

```json
{
  "data": [
    {
      "id": "3ke6kg3wk223e",
      "amount": 100,
      "memo": "补贴",
      "to": {
        "id": "…", "did": "…", "handle": "…", "nickname": "王五", "avatar": null,
        "node_member": false,
        "email": "wangwu@example.com", "phone": "13800000000", "phone_region": "86"
      },
      "inserted_at": "2026-07-29T09:00:00.000000Z"
    }
  ],
  "meta": { "next_cursor": "…" }
}
```

后台这份的 `to` **带联系方式** —— 公开的那份
([grain_grant_controller](../grain_grant_controller.md))不带。

---

## `GET /api/admin/users/:user_id/grain_transfers`

某个用户的稻米明细(收入和支出都在里面)。

| 参数 | 说明 |
| --- | --- |
| `page` `per_page` | 后台表格用页码,见 [分页](../README.md#页码传-page-时) |
| `limit` `before` `after` | 也支持游标,见 [分页](../README.md#分页) |

响应 `200`,`data` 是转账对象数组,形状见
[grain_transfer_controller](../grain_transfer_controller.md#转账对象)。

`direction` 按**这个用户**算,不是按当前登录的管理员算。

`404` —— 用户不存在。
