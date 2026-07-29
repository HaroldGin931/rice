# rice HTTP API

每个控制器一份文档。这里只写**所有接口共通的约定** —— 认证、分页、错误形状。
单个接口的参数和响应看对应的那一份。

迁移背景和与 core 的逐条映射见 [`../backend-migration-plan.md`](../backend-migration-plan.md)。

## 目录

### C 端(`/api/*`)

| 文档 | 控制器 | 管什么 |
| --- | --- | --- |
| [verification_code](verification_code_controller.md) | `VerificationCodeController` | 发短信 / 邮件验证码 |
| [registration](registration_controller.md) | `RegistrationController` | 注册(两步) |
| [session](session_controller.md) | `SessionController` | 登录 / 登出 |
| [password](password_controller.md) | `PasswordController` | 忘记密码 |
| [user](user_controller.md) | `UserController` | 自己的档案、改绑、注销 |
| [attachment](attachment_controller.md) | `AttachmentController` | 附件上传与读取 |
| [app](app_controller.md) | `AppController` | 应用入口 |
| [banner](banner_controller.md) | `BannerController` | 轮播位 |
| [announcement](announcement_controller.md) | `AnnouncementController` | 公告 |
| [settings](settings_controller.md) | `SettingsController` | 基金会公开信息 |
| [node](node_controller.md) | `NodeController` | 节点与节点成员 |
| [badge](badge_controller.md) | `BadgeController` | 某个人的勋章墙 |
| [grain_grant](grain_grant_controller.md) | `GrainGrantController` | 全站发放记录(公开) |
| [grain_transfer](grain_transfer_controller.md) | `GrainTransferController` | 稻米明细与转账 |
| [proposal](proposal_controller.md) | `ProposalController` | 提案 |
| [proposal_vote](proposal_vote_controller.md) | `ProposalVoteController` | 投票 |
| [proposal_comment](proposal_comment_controller.md) | `ProposalCommentController` | 提案评论 |

### 浏览器流程(不在 `/api` 下)

这两个不遵守下面的约定 —— 它们返回 HTML 跳转,不是 JSON。

| 文档 | 控制器 | 管什么 |
| --- | --- | --- |
| [semi_auth](semi_auth_controller.md) | `SemiAuthController` | Login with Semi(OAuth + PKCE)与会话交接 |
| [page](page_controller.md) | `PageController` | 调试用的落地页 |

### 管理端(`/api/admin/*`)

| 文档 | 控制器 | 管什么 |
| --- | --- | --- |
| [admin/session](admin/session_controller.md) | `Admin.SessionController` | 管理端登录(两步) |
| [admin/password](admin/password_controller.md) | `Admin.PasswordController` | 管理员忘记密码 |
| [admin/admin_user](admin/admin_user_controller.md) | `Admin.AdminUserController` | 管理员账号 |
| [admin/catalog](admin/catalog_controller.md) | `Admin.CatalogController` | 应用 / 轮播 / 公告 / 节点 |
| [admin/user](admin/user_controller.md) | `Admin.UserController` | 用户管理 |
| [admin/grain](admin/grain_controller.md) | `Admin.GrainController` | 发放稻米与明细 |
| [admin/proposal](admin/proposal_controller.md) | `Admin.ProposalController` | 提案审核 |
| [admin/badge](admin/badge_controller.md) | `Admin.BadgeController` | 勋章维护 |
| [admin/settings](admin/settings_controller.md) | `Admin.SettingsController` | 全站配置 |
| [admin/template](admin/template_controller.md) | `Admin.TemplateController` | 批量操作的 Excel 模板 |
| [admin/post](admin/post_controller.md) | `Admin.PostController` | 贴文下架 / 恢复 |

## 认证

两套令牌,**互相换不过去**:C 端令牌调不了 `/api/admin/*`,反过来也一样。

```
Authorization: Bearer <token>
```

> core 的管理端把**裸令牌**直接塞进 `Authorization`,没有 `Bearer ` 前缀。
> rice 只认标准写法。

令牌是不透明串,库里只存 sha256。撤销是删行,立刻生效 —— 不像 JWT 要等过期。

三档权限:

| 档 | 谁能过 | 不过时 |
| --- | --- | --- |
| 匿名 | 所有人 | —— |
| 已登录 | 带有效令牌 | `401` |
| `role=admin` | 管理端令牌且角色是 `admin` | `403` |

管理端的 `operator`(运营)能做内容运营,进不了管理员管理。**这层在服务端强制**
—— core 只在前端按角色隐藏菜单,知道路径就能调。

## 响应形状

成功的响应一律包在 `data` 里:

```json
{"data": {"id": "3ke6kg3wk223e", "…": "…"}}
```

列表多一个 `meta`:

```json
{"data": [ … ], "meta": {"next_cursor": "3ke6kg3wk223e"}}
```

没有内容的成功响应是 `204`,body 为空。

## 分页

两种模式,同一批接口。**默认是游标**,传了 `page` 就切成页码。

### 游标(默认)

| 参数 | 说明 |
| --- | --- |
| `limit` | 每页条数,默认 20,上限 100 |
| `before` | 取这个游标**之前**的(更早的一页) |
| `after` | 取这个游标**之后**的 |

```json
{"data": [ … ], "meta": {"next_cursor": "3ke6kg3wk223e"}}
```

`next_cursor` 为 `null` 表示没有下一页。游标是不透明串,别去解析它。
**传坏的游标会被当成没传**,退回第一页,不报错。

没有 `total` —— 信息流用不上,而在大表上 `COUNT(*)` 是最贵的一次查询。

### 页码(传 `page` 时)

| 参数 | 说明 |
| --- | --- |
| `page` | 第几页,从 1 开始 |
| `per_page` | 每页条数,默认 20,上限 100 |

```json
{"data": [ … ], "meta": {"total": 137, "page": 3, "per_page": 15, "next_cursor": "…"}}
```

游标翻不到「第 7 页」—— 它只知道下一页。管理后台的表格是页码式的:运营要跳页、
要知道一共多少条。所以**后台列表按页码走**,代价是每次多一条 `COUNT(*)` 和深翻页的
`OFFSET`。在后台这是划算的:数据量是运营级别的,而且人在看,并发约等于零。

非法的 `page`(0、负数、非数字)当第 1 页,和坏游标退回第一页是同一个取舍。
翻过最后一页返回空数组,不是错误。

C 端信息流仍然走游标 —— 那里才是深翻页和高并发同时出现的地方。

### 不分页的

按 `position` 排序的内容位(应用、轮播、公告、节点)一次全给,两种参数都不认。

## 错误

HTTP 状态码本身表达结果,body 固定是 `{"errors": ...}`。
core 那套「HTTP 永远 200,靠信封里的 `code` 判断成败」在这里没有了。

```json
{"errors": {"detail": "未认证"}}
```

字段级错误(校验失败)按字段分组:

```json
{"errors": {"title": ["不能为空"], "amount": ["必须大于 0"]}}
```

| 状态码 | 什么时候 |
| --- | --- |
| `400` | 请求体不是合法 JSON —— 由 `Plug.Parsers` 抛出,没有哪个 action 会主动返回它 |
| `401` | 没令牌 / 令牌无效或已撤销 |
| `403` | 令牌有效但权限不够 |
| `404` | 资源不存在(**或者不该让你知道它存在**) |
| `422` | 参数校验没过 |
| `429` | 触发频率限制(发码、试码) |
| `502` | 依赖的外部服务(PDS、短信、贴文服务)出错 |
| `503` | 依赖的外部服务没配置 |

有几处**故意不区分**失败原因,因为区分了就等于送出一个探测接口:

- 登录:账号不存在和密码错误都是 `401` + 同一句话
- 重置密码:用户不存在和验证码不对都是 `422` + 「验证码不正确」
- 管理端发重置码:手机号不是管理员时也返回 `202`

## 标识符

主键是 **TSID** —— 13 个字符的字符串,字典序即时间序。不是自增整数,
JSON 里是字符串,别用数字类型接。

几个接口的 `:user_id` 位置接受多种写法:rice id、DID、handle,
`/api/users/:user_id/badges` 还额外认 `"me"`。

## 时间

一律 ISO 8601 带时区,UTC:`2026-07-29T09:00:00.123456Z`。

## 验证码

`channel` 只有 `sms` 和 `email` 两种。`purpose` 决定这个码能干什么 ——
拿注册的码去改绑手机是不行的。

| purpose | 用在哪 |
| --- | --- |
| `register` | 注册 |
| `reset_password` | 忘记密码 |
| `modify_phone` | 改绑手机 |
| `modify_email` | 改绑邮箱 |
| `delete_account` | 注销账号 |
| `admin_login` | 管理端登录(由 `/api/admin/session/challenge` 内部发起) |
| `admin_reset_password` | 管理员重置密码 |

约束:

- 有效期 **30 分钟**
- 同一个 (channel, target, purpose) **60 秒**内只能发一次,否则 `429`
- 最多试 **5 次**,超了作废,要重新发 —— core 那边 6 位码可以无限次猜
