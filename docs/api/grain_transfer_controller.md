# GrainTransferController

稻米流转。替代 core 的 `/score/reward`、`/score/send` 和
`/score/user-sore-record-page`。

**全部接口都要登录。**

共通约定见 [README](README.md)。

---

## 转账对象

```json
{
  "id": "3ke6kg3wk223e",
  "kind": "gift",
  "amount": 50,
  "memo": "谢谢分享",
  "subject_uri": "at://did:plc:…/app.bsky.feed.post/…",
  "from": { "id": "…", "handle": "…", "…": "…" },
  "to":   { "id": "…", "handle": "…", "…": "…" },
  "direction": "out",
  "inserted_at": "2026-07-29T09:00:00.000000Z"
}
```

| 字段 | 说明 |
| --- | --- |
| `kind` | `grant`(后台发放)/ `reward`(打赏内容)/ `gift`(转赠)/ `task_reward`(任务完成奖励) |
| `subject_uri` | 打赏时是贴文 AT URI；任务奖励是 `rice://tasks/:id`；其余为 `null` |
| `direction` | 相对**当前用户**:收到是 `in`,付出是 `out` |
| `from` | 发放没有付款人,是 `null` |

`from` / `to` 都是 `public` 视图,不含联系方式。

> core 是靠给每笔转账写**两行**带符号的记录来表达方向的。这里一笔就是一行,
> `direction` 由查看者算出来。

---

## `GET /api/grain_transfers`

我的稻米明细 —— 我付出的和我收到的都在里面,按时间倒序。

| 参数 | 说明 |
| --- | --- |
| `limit` `before` `after` | 见 [分页](README.md#分页) |

响应 `200`,`data` 是转账对象数组,`meta.next_cursor` 是游标。

只能看自己的。看别人的要走后台
([admin/grain_controller](admin/grain_controller.md#get-apiadminusersuser_idgrain_transfers))。

---

## `POST /api/grain_transfers`

转账。

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `to` | string | 是 | 收款人:rice id、DID、handle、邮箱或手机号 |
| `amount` | integer | 是 | 正整数。字符串数字也收 |
| `kind` | string | 否 | `reward` 或 `gift`(默认) |
| `memo` | string | 否 | 留言 |
| `subject_uri` | string | 否 | 打赏时指向的贴文 AT URI |

`kind` 只认 `reward`,其余一律当 `gift` —— 客户端传不出 `grant`,
也传不出 `task_reward`。发放只能从后台走，任务奖励只能由 Task 状态机结算。

### 响应 `201`

`data` 是转账对象,`direction` 是 `out`。

### 错误

| 状态码 | body |
| --- | --- |
| `401` | 没登录 |
| `422` | `{"errors":{"detail":"金额必须是正整数"}}` |
| `422` | `{"errors":{"amount":["稻米不足"]}}` |
| `422` | `{"errors":{"to":["接收用户不存在"]}}` |
| `422` | `{"errors":{"to":["接收用户已被禁用"]}}` |
| `422` | `{"errors":{"to":["不能转给自己"]}}` |

### 这个接口确实能区分「这个联系方式存不存在」

别处(登录、重置密码)刻意不区分,这里区分。转账界面只有一个输入框,
用户填了个号码转不出去,必须知道是「查无此人」还是「余额不够」。core 也是如此。
想收敛枚举风险要靠限流,不是靠把错误信息含糊掉。

### 一致性

写记录、扣款、入账在**同一个事务**里。余额不足时扣款那一步失败,整笔回滚,
不会留下一条对不上账的记录。

全站可用余额与任务冻结余额之和应当恒等于发放总额（内部转移是零和的），
`Rice.Grains.reconcile/0` 就是对这个的检查,测试里每次转账后都会跑一遍。
