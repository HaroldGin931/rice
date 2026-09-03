# TaskController

Task V1 与稻米奖励结算。读取与结算权威都是 Rice 数据库，不绕 PDS、Relay 或 AppView。

这一版实现：单份草稿、发布、申请领取、发布者从申请人中任命、任命前取消、领取截止
后失效、承作人提交结果、发布者认可结果，或「不认可结果并说明理由」后由同一承作人重新提交。
任务详情公开返回状态变化记录；申请、任命、取消、失效、提交与审核同时产生 Rice 站内通知。

**不实现**指定用户邀约、协作人、执行进度、监督人、争议协调、任务附件、任命后的取消/
退出/延期、节点稻米池和写入 PDS。这些能力不属于当前范围。

任务奖励由发布者自己的可用稻米承担。任务发布时冻结；结果被认可时发给承作人并生成
`task_reward` 流水；任务在任命前取消或失效时退回发布者。节点稻米池仍固定为 `0`，
不参与当前结算。

共通约定见 [README](README.md)。

## 任务状态

| API 值 | 界面文案 | 下一步 |
| --- | --- | --- |
| `draft` | 草稿 | 发布者发布；只有发布者本人可见 |
| `open` | 可领取 | 用户申请，发布者任命 |
| `in_progress` | 进行中 | 承作人提交结果 |
| `under_review` | 待验收 | 发布者认可结果，或不认可并说明理由 |
| `completed` | 已完成 | 终态；继续出现在承作人的历史记录 |
| `expired` | 已失效 | 领取截止前无人获任命；终态 |
| `cancelled` | 已取消 | 发布者在任命前取消；终态 |

不认可结果不会更换承作人：任务回到 `in_progress`，旧提交与不认可理由保留。

## 任务对象

```json
{
  "id": "3ke6kg3wk223e",
  "title": "整理村史访谈",
  "description": "完成访谈文字稿并校对",
  "status": "open",
  "creator": {"id": "…", "handle": "…", "nickname": "…"},
  "assignee": null,
  "application_deadline": "2026-09-10T12:00:00Z",
  "appointed_at": null,
  "appointment_reason": null,
  "published_at": "2026-09-03T14:45:56Z",
  "reward_amount": 120,
  "reward_status": "reserved",
  "application_count": 1,
  "my_application_status": null,
  "allowed_actions": ["apply"],
  "applications": null,
  "submissions": null,
  "events": null,
  "inserted_at": "…",
  "updated_at": "…"
}
```

`reward_status` 为 `none|reserved|settled|refunded`：草稿或零奖励任务是 `none`；发布后的
正数奖励是 `reserved`；认可结果后是 `settled`；取消或失效后是 `refunded`。

`published_at` 取任务第一次进入 `open` 的状态事件时间；草稿为 `null`。`inserted_at`
仍表示任务或草稿最初创建的时间。

`allowed_actions` 是服务端根据当前用户和状态计算的，可包含 `publish`、`apply`、
`appoint`、`cancel`、`submit_result`、`approve_result`、`request_changes`。未登录时为空数组。

详情中，只有发布者能看到 `applications`；只有发布者和承作人能看到 `submissions`。
`events` 只在详情响应出现，按时间正序包含 `from_status`、`to_status`、可选 `detail`、
可选 `actor` 和 `inserted_at`。迁移前已经存在的任务以一条“状态记录从这里开始”
作为历史起点，不伪造此前无法还原的迁移过程。

## 读取

- `GET /api/tasks`：公开列表。支持七种精确状态、`status=closed`（取消或失效）、标题/说明
  关键词 `q` 与共通游标分页参数 `limit`、`before`；草稿不会出现在公开列表。
- `GET /api/tasks/:id`：公开详情；草稿只有发布者本人能读取。
- `GET /api/tasks?mine=assigned|created|applied`：登录时按关系筛选。被任命后，任务从
  `applied` 移到 `assigned`；未获任命、任务取消或失效的申请仍保留在 `applied` 历史中。
  `assigned` 包含已完成任务，因此承作人的历史记录不会因重新登录而丢失。

## 写入（全部需要 C 端登录）

### `POST /api/tasks`

只有 `user.can_publish_tasks=true` 才能发布。

```json
{
  "title":"整理村史访谈",
  "description":"完成访谈文字稿并校对",
  "status":"open",
  "application_deadline":"2026-09-10T12:00:00Z",
  "reward_amount":120
}
```

`status` 只接受创建语义中的 `draft` 或 `open`；省略时为 `open`。每位发布者最多保留
一份 `draft`。领取截止可选，但填写时必须在将来。`reward_amount` 是非负整数；正数奖励在
创建公开任务时立即冻结，余额不足返回 `422` 且任务不会创建。成功 `201`，没有权限 `403`。

### `PATCH /api/tasks/:task_id`

仅发布者可以修改自己的 `draft`。请求字段与创建任务相同，但不接收 `status`。前端读取
唯一草稿后直接继续编辑同一条任务，不会复制出第二条草稿；草稿阶段修改奖励不会冻结。
草稿一旦发布，继续修改返回 `409`。

### `POST /api/tasks/:task_id/publish`

仅发布者可以把自己的 `draft` 发布为 `open`。正数奖励在同一事务里冻结；余额不足或领取
截止已经过去返回 `422`，任务仍保持草稿。

### `POST /api/tasks/:task_id/cancel`

仅发布者可在 `open`、尚未任命时取消。成功后进入 `cancelled`，冻结奖励在同一事务退回；
任命后返回 `409`。

### `POST /api/tasks/:task_id/applications`

```json
{"reason":"做过两次口述史整理，本周可以完成。"}
```

理由选填，最长 512。不能申请自己的任务；同一用户同一任务只能申请一次。

### `POST /api/tasks/:task_id/applications/:application_id/appoint`

```json
{"appointment_reason":"相关经历与本任务最匹配。"}
```

仅发布者可任命一名申请人。成功后任务进入 `in_progress`。申请状态不重复存库：详情
响应会根据任务承作人把被选申请显示为 `appointed`，其他申请显示为 `not_selected`。
任务同时记录 `appointed_at` 和最长 512 字的可选 `appointment_reason`。条件更新保证并发
时只会任命一人。

### `POST /api/tasks/:task_id/submissions`

仅当前承作人可在 `in_progress` 提交：

```json
{"body":"已完成访谈稿与校对，交付链接见说明。"}
```

成功 `201`，任务进入 `under_review`。本版结果只收文字，不收附件。

### `POST /api/tasks/:task_id/submissions/:submission_id/approve`

仅发布者可审核当前待审提交。成功后在同一事务中进入 `completed`、释放发布者冻结余额、
给承作人入账并写入 `task_reward` 流水。重复审核由状态条件更新拦截，不会重复发放。

### `POST /api/tasks/:task_id/submissions/:submission_id/request_changes`

```json
{"reason":"缺少第二位受访者的校对确认，请补齐。"}
```

理由必填，最长 512。成功后写入该次提交的 `review_reason`，任务回到 `in_progress`，
承作人不变，可再次提交。提交的 `pending|approved|changes_requested` 状态由任务状态与
不认可理由计算，不额外维护一份容易失配的状态字段。

## 自动失效

`application_deadline` 到期且任务仍为 `open` 时进入 `expired`。Oban 每分钟执行一次；
列表或详情读取也会幂等补偿一次，因此后台任务暂时关闭的本地环境不会继续接受过期申请。
冻结奖励会退回发布者；所有申请人会收到 `task_expired` 通知，任务仍保留在各自申请历史中。

## 任务通知

- `GET /api/task_notifications`：当前用户最近 50 条任务通知。
- `POST /api/task_notifications/read`：把当前用户未读任务通知标记为已读，成功返回 `204`。

通知事件包括 `application_created`、`assignee_appointed`、`application_not_selected`、
`task_cancelled`、`task_expired`、`result_submitted`、`result_approved` 和
`changes_requested`。这些通知只写 Rice，不写 PDS。

## 状态冲突

动作与当前状态不匹配，或同一状态动作已经被另一个请求先完成时，返回 `409`：

```json
{"errors":{"detail":"资源状态已经变化，请刷新后重试"}}
```
