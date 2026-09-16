# 本人钱包与业务通知

2026-09-15。全部接口使用 Rice 用户令牌，只读取/操作当前账号的数据。

`GET /api/wallet?before=…&limit=20` 返回：

```json
{"data":{"balance":180,"frozen":20,"earned":200,"entries":[],"next_cursor":null}}
```

`balance` 可用、`frozen` 冻结；`earned` 累计收到的转账/测试发放，退款不计收入。
`entries` 合并转账及冻结/退款凭证，按 ID 从新到旧，默认 20、最多 100 条，
通过 `data.next_cursor` 作为下次 `before` 继续读取。没有下一页为 null。

每条含 `id/kind/amount/subject_uri/inserted_at/from_user/to_user`。双方为
`{id,nickname,handle}` 或 null，不含其他私有字段。
`kind` 为 `grant/gift/reward/task_reward/event_fee/reserved/refunded`。
冻结/退款归付款人；转账按本人是收款方还是付款方判定收支。
结算同时产生 transfer 和 settled 凭证，钱包只呈现 transfer，避免金额重复展示。
`rice://tasks/:id` 关联任务；`rice://event_applications/:id` 关联活动申请。
凭证保留在服务端，前端默认显示业务文案，编号按需展开。

`GET /api/notifications` 返回 `{notifications:[…]}`，为当前用户最近 100 条任务、活动和入会通知。
字段为 `uri/reason/record.text/isRead/indexedAt/author/taskId/subjectType/subjectId`。
`subjectType=task|event|node` 及 `subjectId` 用于打开对应详情；保留 reason 的 `task-` 前缀
兼容现有消息适配。不会广播其他账号的入会或资金消息。

`POST /api/notifications/read` 手动将本人的业务通知全部标为已读，返回 `204`。
PDS 社交通知仍使用 PDS 令牌与原接口，不能混用两类令牌。
