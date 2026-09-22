# 本人钱包、社区钱包与业务通知

2026-09-15。全部接口使用 Rice 用户令牌，只读取/操作当前账号的数据。

`GET /api/wallet?before=…&limit=20` 返回：

```json
{"data":{"balance":180,"frozen":20,"earned":200,"entries":[],"next_cursor":null}}
```

`balance` 可用、`frozen` 冻结；`earned` 累计收到的转账/测试发放，退款不计收入。
`entries` 合并转账及冻结/退款凭证，按 ID 从新到旧，默认 20、最多 100 条，
通过 `data.next_cursor` 作为下次 `before` 继续读取。没有下一页为 null。

每条含 `id/kind/amount/subject_uri/inserted_at/from_user/to_user/from_node/to_node`。
用户端为 `{id,nickname,handle}`，社区端为 `{id,name}`，未使用的端点为 null，不含其他私有字段。
`kind` 为 `grant/gift/reward/task_reward/event_fee/community_fund/reserved/refunded`。
冻结/退款归付款人；转账按本人是收款方还是付款方判定收支。
结算同时产生 transfer 和 settled 凭证，钱包只呈现 transfer，避免金额重复展示。
`rice://tasks/:id` 关联任务；`rice://event_applications/:id` 关联活动申请。
凭证保留在服务端，前端默认显示业务文案，编号按需展开。

## 社区账户（2026-09-21）

`GET /api/nodes/:node_id/wallet?before=…&limit=20` 使用相同钱包结构与分页，只有该社区管理员可读。
每个社区账户初始可用及冻结均为 0；个人账户保留，不因取得管理员角色而移动余额。

`POST /api/nodes/:node_id/fund` 由管理员显式从本人账户转入社区：

```json
{"amount":40,"client_request_id":"本次操作的唯一标识"}
```

`amount` 是 1 至 999999999 的 JSON 整数；负数、小数、字符串不会被截取或改写，返回 422。
请求标识必填、1–128 字节；同一管理员向同一社区用相同标识和金额重试不重复扣款，
标识相同但金额不同返回 409。余额不足返回 422，权限不足 403；操作失败整笔回滚。
成功返回更新的社区钱包 `{data: …}`，个人及社区明细共用一笔 `community_fund` 流水。

新任务从社区可用稻米冻结奖励，取消退回同一社区，验收后支付到承作人个人账户；
新活动仍在申请时冻结申请人个人报名费，确认结束后结算到社区。
`tasks.funding_node_id`、`events.settlement_node_id` 固定业务的资金归属。
迁移前已发布记录的两个字段保留 null，继续使用原发布者个人账户；未发布草稿在发布时采用社区账户。
既有余额、冻结和历史流水均不回填或转移，对账包含个人与社区可用及冻结总额。

## 业务通知

`GET /api/notifications` 返回 `{notifications:[…]}`，为当前用户最近 100 条任务、活动和入会通知。
字段为 `uri/reason/record.text/isRead/indexedAt/author/taskId/subjectType/subjectId`。
`subjectType=task|event|node` 及 `subjectId` 用于打开对应详情；保留 reason 的 `task-` 前缀
兼容现有消息适配。不会广播其他账号的入会或资金消息。

2026-09-22：任务、活动通知的 `record.text` 包含对应名称。活动退款与结束结算通知同时
显示本人的报名费金额，免费活动不显示金额；任务原有结算金额保留，取消后奖励已退回时
显示金额并明确退回社区或原发布者，不表示申请人收到退款。读取时关联业务记录补齐历史
通知，不重写通知或资金记录；旧任务通知仍按 `task_id` 关联，详情跳转字段保持不变。
活动记录不存在时保留原通知正文，避免影响整批通知读取。

`POST /api/notifications/read` 手动将本人的业务通知全部标为已读，返回 `204`。
PDS 社交通知仍使用 PDS 令牌与原接口，不能混用两类令牌。
