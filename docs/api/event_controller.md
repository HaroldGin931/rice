# EventController

## 联系方式（2026-09-21）

创建与草稿编辑接受 `organizer_contact`（去除首尾空白、最多 256 字），公开发布必填；
草稿可以暂不填写，调用 `publish` 时再次校验。公开详情及列表返回该字段，供访客联系组织方。
旧记录可为 `null`，迁移不伪造联系方式，也不阻止读取或处理既有申请。

申请接口接受必填 `contact`（去除首尾空白、最多 256 字）。缺失、空白或超长返回 `422`
及对应字段错误。联系方式只进入申请人本人的详情 `my_application.contact` 和有管理权限的
组织方详情 `applications[].contact`；公共详情、其他参与者及所有列表响应均不返回申请人联系方式。
幂等重试返回原申请，不覆盖已保存联系方式；不在通知或公开历史中复制该字段。


2026-09-21：活动直接存 Rice。社区管理员从候选名单录取；申请时冻结费用但不占名额，
通过才占名额。已通过人数达到容量后，不再接受新的申请。开始由系统处理，结束由主办方确认。
共通格式见 [README](README.md)。

| 接口 | 用途 |
| --- | --- |
| `GET /api/events` | 公开列表，排除草稿；支持 `q/node_id/status`、标准分页 |
| `GET /api/events?mine=created\|applied\|managed` | 本人主办、申请或共同管理记录；managed 包含本人草稿及所管理社区的非草稿活动 |
| `GET /api/events?creator_did=…` | 公开主办履历 |
| `GET /api/events?participant_did=…` | 有效 `approved` 参与履历，不公开未录取申请 |
| `GET /api/events/:id` | 详情；草稿只有主办方可读 |
| `POST /api/events` | 创建草稿或直接发布，只有目标节点唯一管理员可用 |
| `PATCH /api/events/:event_id` | 修改草稿；发布后禁止修改核心约定 |
| `POST /api/events/:event_id/publish` | 发布草稿 |
| `POST /api/events/:event_id/applications` | 登录用户申请，`reason` 可选、最多 512 字；满员时新申请返回 `409`，不冻结费用 |
| `POST /api/events/:event_id/applications/:application_id/approve` | 通过候选，活动开始前可用，达到人数上限返回 `409` |
| 同路径尾部 `reject` | 拒绝待审批申请并退回冻结费用 |
| 同路径尾部 `remove` | 移除已通过报名并退款、释放名额；完成前可用 |
| 同路径尾部 `withdraw` | 申请人撤销本人的待审批申请；活动开始前可用，全额退回冻结费用 |
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

正文图片由 `attachment_ids` 按顺序指定，最多 9 张本人上传的图片；省略保留，`[]` 移除。
列表与详情均返回有序 `attachments`，每项含 `id/kind/filename/content_type/byte_size/url`。
完整校验及访问规则见 [正文图片](attachment_controller.md#任务与活动正文图片)。

申请状态为 `pending/approved/rejected/removed/withdrawn/not_selected/cancelled`；支付状态为
`none/reserved/refunded/settled`。结束后有效申请仍为 `approved`，付费项变为 `settled`。
主办方看全部申请，本人看自己的申请，公众看不到候选名单和理由。详情历史遵守相同范围；
公众只见活动级别进展。`allowed_actions` 由后端计算，申请项另有自己的审批动作列表。
`can_manage` 表示当前管理权：社区管理员共同管理非草稿活动，草稿仍仅本人可读写。
普通成员与撤权管理员不能读取他人的申请联系方式或执行审批。历史个人收款活动保留原发布者管理权。

每分钟的 `Rice.Workers.StartEvents` 找到已到 `starts_at` 的活动，在同一事务内将剩余
pending 申请设为未入选并原路退款，然后推进活动状态。失败由 Oban 重试，不依赖打开页面。
结束时间本身不结算；主办方确认结束时先完成待处理候选退款，再处理有效报名。
新活动的 `settlement_node_id` 指向所属社区，报名费结算到社区账户；个人管理员不代收。
未发布的旧草稿发布时采用社区收款，已发布的旧活动保留 null 并继续原发布者个人收款。
退款仍全额退回原申请人，迁移不改写既有余额或冻结，参见[社区钱包](wallet_and_inbox.md)。
`status` 是持久化状态，定时处理之前可能短暂仍为 `open`；报名资格直接按当前时间检查，
不等待定时任务。界面应结合 `application_deadline/starts_at/ends_at` 显示截止、进行中或待结束确认，
不能仅凭 `open` 显示报名中，也不能仅凭 `ends_at` 已到显示已完成结算。

报名时间内 `approved_count >= capacity` 显示“已满”，`allowed_actions` 不包含新申请的
`apply`。提交端在活动行锁内再次检查当前容量；满员返回 `409` 和“活动已满，暂无可用名额”，
不写申请、冻结凭证、通知或历史。免费活动遵守同一容量规则。已有申请重试仍返回原记录，
待审批候选仍可自行撤销或由组织方拒绝；不自动创建候补或改变此前申请的冻结状态。
移除已通过报名释放名额后，若仍在报名时间内，则恢复接受新申请。

所有写动作锁活动行；批量资金操作按用户 ID 顺序锁账户。业务状态和资金凭证同事务提交。
同一申请的冻结只能退款或结算一次；重复申请、开始、结束、取消返回原结果，不重复处理。
余额不足为 `422`，非主办方审批为 `403`，已结束后取消等冲突为 `409`。
不提供已通过后的自助退出、撤销或拒绝后重报、部分退款或缺席退款接口。

## 撤销待审批申请

`POST /api/events/:event_id/applications/:application_id/withdraw` 无需额外字段，返回 `200`
和完整活动对象。仅申请人本人可操作；申请须为 `pending`，活动须为 `open`，当前时间须严格
早于 `starts_at`。报名截止后、活动开始前仍可撤销；达到开始时间后即使定时任务尚未执行也不可撤销。
只有满足这些条件时，本人 `my_application.allowed_actions` 才包含 `withdraw`。

成功后申请为 `withdrawn`（已撤销），收费项为 `refunded` 并全额退回原冻结费用，免费项保持
`none`。保留申请和 `application_withdrawn` 历史，不删除或重新开放申请；每人每场仍只有一份申请。
撤销与审批、系统开始共用活动行锁，退款、状态及通知同一事务提交。本人重复撤销已撤销申请返回
原结果，不重复退款或通知，包括原撤销成功后活动已经开始的重试。

未登录返回 `401`，操作他人申请返回 `403`，申请不存在或不属于该活动返回 `404`；已通过、
被拒绝、已移除、已取消、未入选或不满足活动时间条件返回 `409`。主办方继续使用 `reject/remove`，
不能代替申请人调用 `withdraw`。已撤销的申请不会参与活动开始、结束或整场取消的后续资金处理。

部署须先执行 `20260920233500_allow_event_application_withdrawal` 迁移，再开放撤销接口。
已有 `withdrawn` 记录后，直接回滚旧约束会安全失败；迁移事务保留现有约束，不把撤销历史改写为其他状态。
