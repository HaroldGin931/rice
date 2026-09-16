# TaskController

Task V1 与稻米奖励结算。读取与结算权威都是 Rice 数据库，不绕 PDS、Relay 或 AppView。

2026-09-15：单份草稿、节点唯一管理员发布、公开申请、选定一人、任命前取消、成果提交、
退回重交和一次验收发放。申请截止只关闭新申请，不失效、不退款；执行逾期保留人和冻结款。
任务详情返回可见范围内的状态记录，申请及业务动作产生 Rice 站内通知。

**不实现**指定用户邀约、协作人、执行进度、监督人、争议协调、成果附件、任命后的取消/
退出/延期、额外资金池和写入 PDS。这些能力不属于当前范围。

任务奖励由发布者自己的可用稻米承担。任务发布时冻结；结果被认可时发给承作人并生成
`task_reward` 流水；任务在任命前取消时退回发布者。`nodes.user_id` 是唯一管理员及出资人，
社区和管理员使用同一账户，不另外建立社区余额。每笔冻结与其退款或结算有唯一凭证。

共通约定见 [README](README.md)。

## 任务状态

| API 值 | 界面文案 | 下一步 |
| --- | --- | --- |
| `draft` | 草稿 | 发布者发布；只有发布者本人可见 |
| `open` | 招募中 | 截止前用户申请；发布者可继续从已有候选中选人 |
| `in_progress` | 进行中 | 承作人提交结果 |
| `under_review` | 待验收 | 发布者认可结果，或不认可并说明理由 |
| `completed` | 已完成 | 终态；继续出现在承作人的历史记录 |
| `expired` | 已结束 | 仅兼容旧记录；新规则不产生此状态 |
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
正数奖励是 `reserved`；认可结果后是 `settled`；取消后是 `refunded`。

对象另外返回 `node`、`requirement`、`execution_deadline`、`application_closed`、`overdue`，
以及当前用户的 `my_application`（含本人理由与状态）。`appointment_reason` 只返回给发布者和承接者。

正文图片由创建/草稿编辑请求的 `attachment_ids` 指定，最多 4 张、按数组顺序；列表和详情
均返回有序 `attachments`。上传归属、替换/移除及 URL 规则见 [正文图片](attachment_controller.md#任务与活动正文图片)。

`published_at` 取任务第一次进入 `open` 的状态事件时间；草稿为 `null`。`inserted_at`
仍表示任务或草稿最初创建的时间。

`allowed_actions` 是服务端根据当前用户和状态计算的，可包含 `publish`、`apply`、
`appoint`、`reject_application`、`cancel`、`submit_result`、`approve_result`、`request_changes`。
`appoint` 和 `reject_application` 仅在任务仍招募且有待处理申请时向发布者提供。未登录时为空数组。

详情中，只有发布者能看到 `applications`；只有发布者和承作人能看到 `submissions`。
`events` 只在详情响应出现，按时间正序包含 `from_status`、`to_status`、可选 `detail`、
可选 `actor` 和 `inserted_at`。迁移前已经存在的任务以一条“状态记录从这里开始”
作为历史起点，不伪造此前无法还原的迁移过程。
申请事件仅发布者或该申请人可见，承接者不能通过事件列表查看其他候选人身份。
公开进展不含选人说明、验收退回理由等私有内容。

## 读取

- `GET /api/tasks`：公开列表。支持七种精确状态、`status=closed`（取消或失效）、标题/说明
  关键词 `q` 与共通游标分页参数 `limit`、`before`；草稿不会出现在公开列表。
- `GET /api/tasks/:id`：公开详情；草稿只有发布者本人能读取。
- `GET /api/tasks?mine=assigned|created|applied`：登录时按关系筛选。被任命后，任务从
  `applied` 移到 `assigned`；未获任命、任务取消或失效的申请仍保留在 `applied` 历史中。
  `assigned` 包含已完成任务，因此承作人的历史记录不会因重新登录而丢失。
- `node_id` 筛选社区；`available=true` 根据当前用户、截止及是否已申请筛出可申请任务。
- `creator_did` 查公开发布履历；`participant_did` 只查实际承接履历，不公开未入选申请。

## 写入（全部需要 C 端登录）

### `POST /api/tasks`

只有目标节点 `nodes.user_id` 指向的用户才能发布；不再以全局 `can_publish_tasks` 开关授权。
传 `node_id`；省略时仅在该用户恰好管理一个节点时推导。每次创建须传非空、最多 128 字节的
`client_request_id`，同一用户以同一标识重试返回原任务，不能重新冻结。

```json
{
  "title":"整理村史访谈",
  "node_id":"节点 TSID",
  "client_request_id":"本次创建的固定 UUID",
  "description":"完成访谈文字稿并校对",
  "attachment_ids":[],
  "requirement":"交付校对后的文字稿",
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
草稿的所属节点固定；可改 `requirement`、`execution_deadline`，交付截止应晚于现在及申请截止。

### `POST /api/tasks/:task_id/publish`

仅发布者可以把自己的 `draft` 发布为 `open`。正数奖励在同一事务里冻结；余额不足或领取
截止或交付截止已经过去返回 `422`，任务仍保持草稿。发布时锁定并重读当前草稿，避免编辑与
发布并发时使用旧金额。已发布任务重试返回原任务。

### `POST /api/tasks/:task_id/cancel`

仅发布者可在 `draft` 或 `open`、尚未任命时取消。成功后进入 `cancelled`，冻结奖励在同一事务退回；
任命后返回 `409`。

### `POST /api/tasks/:task_id/applications`

```json
{"reason":"做过两次口述史整理，本周可以完成。"}
```

理由选填，最长 512。不能申请自己的任务；同一用户同一任务只有一份申请，开放期内重复请求
返回原申请且不重复通知。无需先加入社区。申请截止后返回 `409`。
已被拒绝的申请也不会重新进入候选队列；开放期内重复提交仍返回原申请的未入选结果。

### `POST /api/tasks/:task_id/applications/:application_id/reject`

请求无需额外字段。仅发布者可以拒绝 `open` 任务中尚未任命的申请，申请截止后仍可处理。
成功返回 `200` 和更新后的完整任务对象；被拒申请的 `status` 和本人 `my_application_status`
均为 `not_selected`，任务继续招募，其他候选不受影响。拒绝不改变任务奖励与冻结余额。
发布者和申请人本人可见该申请的结果，公众看不到申请列表。

申请只新增可空的 `rejected_at` 时间用于记住主动拒绝；旧记录的空值继续按原规则计算状态。
同一招募中任务重复拒绝返回成功，但只发送一次 `application_not_selected` 通知。
非发布者返回 `403`，不存在或不属于该任务的申请返回 `404`，已任命或任务已结束返回 `409`。
拒绝和任命共用任务行锁，先被拒绝的申请不能再被任命。

### `POST /api/tasks/:task_id/applications/:application_id/appoint`

```json
{"appointment_reason":"相关经历与本任务最匹配。"}
```

仅发布者可任命一名未被拒绝的申请人。成功后任务进入 `in_progress`。申请状态不重复存库：详情
响应会根据任务承作人把被选申请显示为 `appointed`，其他申请显示为 `not_selected`。
任务同时记录 `appointed_at` 和最长 512 字的可选 `appointment_reason`。任务行锁与条件更新
保证并发时只会任命一人，也不会任命已拒绝的申请；主动拒绝过的申请不会再次收到未入选通知。

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

## 截止与逾期

`application_deadline` 到期后服务端拒绝新申请；已有候选仍可被任命。Oban 每分钟补一条
“申请已截止”记录，不修改状态或余额。执行逾期也只记一次事件并通知承接者，不自动付款、
取消、延期或更换承接者。GET 为纯读取；关闭新申请的判断直接使用当前时间，不依赖定时器已运行。

## 任务通知

- `GET /api/task_notifications`：当前用户最近 50 条任务通知。
- `POST /api/task_notifications/read`：把当前用户未读任务通知标记为已读，成功返回 `204`。

通知事件包括 `application_created`、`assignee_appointed`、`application_not_selected`、
`task_cancelled`、`task_overdue`、`result_submitted`、`result_approved` 和
`changes_requested`。新前端统一使用 [业务通知](wallet_and_inbox.md)；旧任务通知读取路径仍可用。

## 状态冲突

动作与当前状态不匹配，或同一状态动作已经被另一个请求先完成时，返回 `409`：

```json
{"errors":{"detail":"资源状态已经变化，请刷新后重试"}}
```
