# TaskController

Task V1。读取权威是 Rice 数据库，不绕 PDS、Relay 或 AppView。

这一版实现：保存和继续编辑草稿、发布、申请领取、发布者从申请人中任命、领取前取消、领取截止
后失效、承作人提交结果、发布者审核通过，或「驳回并留言」后由同一承作人重新提交。
**不实现**指定用户邀约、协作人、进度、监督、争议、任务附件和稻米结算。

节点稻米池与任务奖励的 API/口径尚未确认：响应没有奖励字段，审核通过后直接完成，
不会冻结、划转或生成流水。

共通约定见 [README](README.md)。

## 任务状态

| API 值 | 界面文案 | 下一步 |
| --- | --- | --- |
| `draft` | 草稿 | 发布者发布；只有发布者本人可见 |
| `open` | 可领取 | 用户申请，发布者任命 |
| `in_progress` | 进行中 | 承作人提交结果 |
| `under_review` | 待审核 | 发布者审核通过或驳回并留言 |
| `completed` | 已完成 | 终态；继续出现在承作人的历史记录 |
| `expired` | 已失效 | 领取截止前无人获任命；终态 |
| `cancelled` | 已取消 | 发布者在任命前取消；终态 |

驳回并留言不会更换承作人：任务回到 `in_progress`，旧提交与驳回原因保留。

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
  "application_count": 1,
  "my_application_status": null,
  "allowed_actions": ["apply"],
  "applications": null,
  "submissions": null,
  "inserted_at": "…",
  "updated_at": "…"
}
```

`allowed_actions` 是服务端根据当前用户和状态计算的，可包含 `publish`、`apply`、
`appoint`、`cancel`、`submit_result`、`approve_result`、`request_changes`。未登录时为空数组。

详情中，只有发布者能看到 `applications`；只有发布者和承作人能看到 `submissions`。

## 读取

- `GET /api/tasks`：公开列表。支持七种状态与共通分页参数，但草稿不会出现在公开列表。
- `GET /api/tasks/:id`：公开详情；草稿只有发布者本人能读取。
- `GET /api/tasks?mine=assigned|created|applied`：登录时按关系筛选；`applied` 只返回仍
  处于 `open` 的待处理申请，任命后会从“我申请中”移到 `assigned`；`assigned` 包含
  已完成任务，因此承作人的历史记录不会因重新登录而丢失。

## 写入（全部需要 C 端登录）

### `POST /api/tasks`

只有 `user.can_publish_tasks=true` 才能发布。

```json
{
  "title":"整理村史访谈",
  "description":"完成访谈文字稿并校对",
  "status":"open",
  "application_deadline":"2026-09-10T12:00:00Z"
}
```

`status` 只接受创建语义中的 `draft` 或 `open`；省略时为 `open`。领取截止可选，但填写时
必须在将来。成功 `201`，没有权限 `403`。

### `PATCH /api/tasks/:task_id`

仅发布者可以修改自己的 `draft`。请求字段与创建任务相同，但不接收 `status`；前端的
“导入草稿”会先读取草稿，再通过本接口更新同一条任务，不会复制出第二条草稿。草稿一旦
发布，继续修改返回 `409`。

### `POST /api/tasks/:task_id/publish`

仅发布者可以把自己的 `draft` 发布为 `open`。如果领取截止已经过去，返回 `422`。

### `POST /api/tasks/:task_id/cancel`

仅发布者可在 `open`、尚未任命时取消。成功后进入 `cancelled`；任命后返回 `409`。

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

仅发布者可审核当前待审提交。成功后直接进入 `completed`；完成时间使用任务自身的
`updated_at`，这一版没有独立结算步骤。

### `POST /api/tasks/:task_id/submissions/:submission_id/request_changes`

```json
{"reason":"缺少第二位受访者的校对确认，请补齐。"}
```

理由必填，最长 512。成功后写入该次提交的 `review_reason`，任务回到 `in_progress`，
承作人不变，可再次提交。提交的 `pending|approved|changes_requested` 状态由任务状态与
驳回理由计算，不额外维护一份容易失配的状态字段。

## 自动失效

`application_deadline` 到期且任务仍为 `open` 时进入 `expired`。Oban 每分钟执行一次；
列表或详情读取也会幂等补偿一次，因此后台任务暂时关闭的本地环境不会继续接受过期申请。

## 状态冲突

动作与当前状态不匹配，或同一状态动作已经被另一个请求先完成时，返回 `409`：

```json
{"errors":{"detail":"资源状态已经变化，请刷新后重试"}}
```
