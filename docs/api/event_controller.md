# EventController

2026-09-15：活动直接存 Rice。唯一社区管理员从候选名单录取；申请时冻结费用但不占名额，
通过才占名额。开始由系统处理，结束由主办方确认。共通格式见 [README](README.md)。

| 接口 | 用途 |
| --- | --- |
| `GET /api/events` | 公开列表，排除草稿；支持 `q/node_id/status`、标准分页 |
| `GET /api/events?mine=created\|applied` | 当前用户主办或申请记录 |
| `GET /api/events?creator_did=…` | 公开主办履历 |
| `GET /api/events?participant_did=…` | 有效 `approved` 参与履历，不公开未录取申请 |
| `GET /api/events/:id` | 详情；草稿只有主办方可读 |
| `POST /api/events` | 创建草稿或直接发布，只有目标节点唯一管理员可用 |
| `PATCH /api/events/:event_id` | 修改草稿；发布后禁止修改核心约定 |
| `POST /api/events/:event_id/publish` | 发布草稿 |
| `POST /api/events/:event_id/applications` | 登录用户申请，`reason` 可选、最多 512 字 |
| `POST /api/events/:event_id/applications/:application_id/approve` | 通过候选，活动开始前可用，达到人数上限返回 `409` |
| 同路径尾部 `reject` | 拒绝待审批申请并退回冻结费用 |
| 同路径尾部 `remove` | 移除已通过报名并退款、释放名额；完成前可用 |
| `POST /api/events/:event_id/cancel` | 取消活动，退回全部尚未结算费用 |
| `POST /api/events/:event_id/finish` | 实际结束时间后由主办方确认，结算仍有效的已通过报名 |

创建/编辑字段：`node_id/title/description/location/application_deadline/starts_at/ends_at/fee_amount/capacity/attachment_ids`。
创建另接受 `status=draft|open`（默认 open）及 `client_request_id`。
发布请求须有固定、非空、最多 128 字节的重试标识；同一主办方同一标识返回原活动。
每位主办方只有一份活动草稿。时间须满足现在 < 报名截止 ≤ 开始 < 结束；容量为正整数，
费用为非负整数，0 表示免费。成功创建为 `201`，其他动作成功为 `200`。

活动状态为 `draft/open/in_progress/completed/cancelled`。响应包含基础字段及 `node/creator`、
`application_count/approved_count`、`my_application/applications`、`history/allowed_actions`。
列表放在 `data` 数组并提供 `meta.next_cursor`，详情放在 `data` 对象。

正文图片由 `attachment_ids` 按顺序指定，最多 4 张本人上传的图片；省略保留，`[]` 移除。
列表与详情均返回有序 `attachments`，每项含 `id/kind/filename/content_type/byte_size/url`。
完整校验及访问规则见 [正文图片](attachment_controller.md#任务与活动正文图片)。

申请状态为 `pending/approved/rejected/removed/not_selected/cancelled`；支付状态为
`none/reserved/refunded/settled`。结束后有效申请仍为 `approved`，付费项变为 `settled`。
主办方看全部申请，本人看自己的申请，公众看不到候选名单和理由。详情历史遵守相同范围；
公众只见活动级别进展。`allowed_actions` 由后端计算，申请项另有自己的审批动作列表。

每分钟的 `Rice.Workers.StartEvents` 找到已到 `starts_at` 的活动，在同一事务内将剩余
pending 申请设为未入选并原路退款，然后推进活动状态。失败由 Oban 重试，不依赖打开页面。
结束时间本身不结算；主办方确认结束时先完成待处理候选退款，再处理有效报名。

所有写动作锁活动行；批量资金操作按用户 ID 顺序锁账户。业务状态和资金凭证同事务提交。
同一申请的冻结只能退款或结算一次；重复申请、开始、结束、取消返回原结果，不重复处理。
余额不足为 `422`，非主办方审批为 `403`，已结束后取消等冲突为 `409`。不提供自助撤回、
拒绝后重报、部分退款或缺席退款接口。
