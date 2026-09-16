# NodeController

2026-09-15：公开社区目录与独立入会申请。节点的 `user_id` 是唯一管理员；成员身份来自
`node_memberships`，不是用户旧的全局 `node_member` 开关。加入社区不是申请任务或活动的门槛。

| 接口 | 行为 |
| --- | --- |
| `GET /api/nodes` | 公开目录，`q` 按名称/介绍搜索；按 `position` 排序，一次返回全部 |
| `GET /api/nodes?mine=identity` | 本人管理、加入或正在申请的社区；需登录 |
| `GET /api/nodes?mine=managed\|joined\|pending` | 按本人对应关系筛选；需登录 |
| `GET /api/nodes/:id` | 社区介绍、成员、当前用户的身份和申请状态 |
| `GET /api/nodes/:node_id/members` | 该社区管理员及正式成员，排除停用/注销用户 |
| `POST /api/nodes/:node_id/applications` | 登录用户申请加入，`reason` 可选、最长 512 |
| `POST /api/nodes/:node_id/applications/:application_id/approve` | 唯一管理员通过申请并建立成员身份 |
| `POST /api/nodes/:node_id/applications/:application_id/reject` | 唯一管理员拒绝；`review_reason` 可选、最长 512 |

列表返回 `{data: [node]}`；详情和写动作返回 `{data: node}`。
基础字段为 `id/name/description/logo/position/owner`；`position` 只作排序，不是用户内容。
`owner` 为公开用户对象，不含联系方式、余额或令牌。

`role` 为 `admin/member/null`。`my_application` 仅含本人的最近一次申请，字段为
`id/status/reason/review_reason/inserted_at/reviewed_at`；`status` 为 `pending/approved/rejected`。
详情里的 `members` 是 `{user, role}` 数组；只有管理员收到 `applications` 完整历史及申请人。
公开访问不展示入会记录；申请人不能查看其他人的申请理由或审批历史。

重复待审批申请返回原记录；通过/拒绝相同动作可安全重试。拒绝后重新申请创建新记录，
保留旧历史。所有审批检查都在服务端，同一节点的变更按行锁串行处理。

`GET /api/nodes/members` 仍兼容旧全局 `node_member=true` 名单；新前端使用节点级接口，
不把旧名单当作社区身份来源。创建节点、移出成员和管理员交接不在当前用户流程中。
