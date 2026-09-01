# TaskController

Task V1。读取权威是 Rice 数据库，不绕 PDS、Relay 或 AppView。

这一版只实现：发布、申请领取、发布者任命、承作人提交结果、发布者审核通过，或
「驳回并留言」后由同一承作人重新提交。**不实现**草稿、取消、邀请、协作人、进度、
监督、争议、任务附件和稻米结算。

节点稻米池与任务奖励的 API/口径尚未确认：响应没有奖励字段，审核通过后直接完成，
不会冻结、划转或生成流水。

共通约定见 [README](README.md)。

## 任务状态

| API 值 | 界面文案 | 下一步 |
| --- | --- | --- |
| `open` | 可领取 | 用户申请，发布者任命 |
| `in_progress` | 进行中 | 承作人提交结果 |
| `under_review` | 待审核 | 发布者审核通过或驳回并留言 |
| `completed` | 已完成 | 终态；继续出现在承作人的历史记录 |

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
  "application_count": 1,
  "my_application_status": null,
  "allowed_actions": ["apply"],
  "applications": null,
  "submissions": null,
  "inserted_at": "…",
  "updated_at": "…"
}
```

`allowed_actions` 是服务端根据当前用户和状态计算的，可包含 `apply`、`appoint`、
`submit_result`、`approve_result`、`request_changes`。未登录时为空数组。

详情中，只有发布者能看到 `applications`；只有发布者和承作人能看到 `submissions`。

## 读取

- `GET /api/tasks`：公开列表。支持 `status=open|in_progress|under_review|completed` 与
  共通分页参数。
- `GET /api/tasks/:id`：公开详情；登录后会增加与当前用户有关的动作和私有记录。
- `GET /api/tasks?mine=assigned|created|applied`：登录时按关系筛选；`applied` 只返回仍
  处于 `open` 的待处理申请，任命后会从“我申请中”移到 `assigned`；`assigned` 包含
  已完成任务，因此承作人的历史记录不会因重新登录而丢失。

## 写入（全部需要 C 端登录）

### `POST /api/tasks`

只有 `user.can_publish_tasks=true` 才能发布。

```json
{"title":"整理村史访谈","description":"完成访谈文字稿并校对"}
```

成功 `201`，任务直接进入 `open`。没有权限 `403`。

### `POST /api/tasks/:task_id/applications`

```json
{"reason":"做过两次口述史整理，本周可以完成。"}
```

理由选填，最长 512。不能申请自己的任务；同一用户同一任务只能申请一次。

### `POST /api/tasks/:task_id/applications/:application_id/appoint`

仅发布者可任命一名申请人。成功后任务进入 `in_progress`。申请状态不重复存库：详情
响应会根据任务承作人把被选申请显示为 `appointed`，其他申请显示为 `not_selected`。
任务的条件更新保证并发时只会任命一人。

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

## 状态冲突

动作与当前状态不匹配，或同一状态动作已经被另一个请求先完成时，返回 `409`：

```json
{"errors":{"detail":"资源状态已经变化，请刷新后重试"}}
```
