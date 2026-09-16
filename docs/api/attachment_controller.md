# AttachmentController

附件上传与读取。替代 core 的 `/api/v1/file/upload` 和 `/file/download`。

共通约定见 [README](README.md)。

---

## 附件对象

附件内嵌在别的响应里(头像、logo、公告附件……)时是这个形状:

```json
{
  "id": "3ke6kg3wk223e",
  "kind": "image",
  "filename": "avatar.png",
  "content_type": "image/png",
  "byte_size": 20480,
  "url": "/api/attachments/3ke6kg3wk223e"
}
```

单个附件为空时是 `null`；任务和活动的 `attachments` 是有序数组，没有图片时为 `[]`。

---

## `POST /api/attachments`

上传。**需要登录。**

用户上传记录归属当前 Rice 登录用户；客户端不能传 `user_id` 指定归属。
历史导入及管理端附件没有用户归属，继续沿用原读取方式，不允许作为新任务/活动正文图片引用。

`multipart/form-data`:

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `file` | file | 是 | |
| `kind` | string | 否 | `image`(默认)或 `file` |

### 限制

- 单文件大小上限 **20 MiB**（20 × 1024 × 1024 字节）。multipart请求解析上限为21 MiB，留出表单包装开销；JSON和普通表单的原请求上限不变。
- content-type 走白名单:
  - `kind=image`:`image/png` `image/jpeg` `image/gif` `image/webp` `image/svg+xml`
  - `kind=file`:`application/pdf` `text/html` `text/plain`
    `application/msword`
    `application/vnd.openxmlformats-officedocument.wordprocessingml.document`
    `application/vnd.ms-excel`
    `application/vnd.openxmlformats-officedocument.spreadsheetml.sheet`

表格新旧格式都收 —— 后台的批量操作模板是 Excel,见
[admin/template_controller](admin/template_controller.md)。注意它算 `file`
不算 `image`,`kind` 传错一样会被拒。

### 响应 `201`

`data` 是附件对象。

### 错误

| 状态码 | body |
| --- | --- |
| `401` | 没登录 |
| `422` | `{"errors":{"file":["缺少上传文件"]}}` |
| `422` | 超大 / 类型不在白名单(changeset 错误) |

### 与 core 的差别

core 的 `/api/v1/file/upload` 标着 `AllowAnonymous` —— **任何人都能往服务器
写文件**,没有身份,没有配额,类型也不查。这里由路由上的
`require_authenticated_user` 拦住,大小和类型在 `Rice.Files` 里校验。

落盘路径**只由 TSID 决定**,任何时候都不把用户提供的文件名拼进路径。
原始文件名只在下载时的 `Content-Disposition` 里出现;上传时还会先取一次
`Path.basename` —— 客户端可以在 `filename` 里塞路径。

## 任务与活动正文图片

先逐张调用上述上传接口，再把返回的 ID 按显示顺序提交给任务或活动的创建/草稿编辑接口：

```json
{"description":"一起整理公共客厅", "attachment_ids":["图片一的 TSID", "图片二的 TSID"]}
```

- `attachment_ids` 可选，最多 **4** 张，不能重复；每个 ID 必须存在、已有存储内容、
  `kind=image` 且属于当前发布者。无效列表返回 `422`，错误字段为 `attachment_ids`。
- 省略字段时保留原图；`[]` 移除全部；非空数组整体替换顺序和选择。正文与关联同事务保存。
- 只可修改草稿。草稿发布及直接发布均保留图片顺序；原有无图片调用继续有效。
- 任务/活动列表与详情返回 `attachments`，每项就是上面的附件对象；不返回上传者 ID 或存储路径。
- 移除图片只解除业务关联，不删除上传文件。图片 URL 延续附件接口公开读取语义；草稿的正文和图片列表仍只有发布者可读。
- 普通帖子仍走 PDS；这里的业务图片存储、上传和读取全部走 Rice。

---

## `GET /api/attachments/:id`

读取。公开,不需要登录。

返回的是**文件字节本身**,不是 JSON。

| 参数 | 说明 |
| --- | --- |
| `download` | `1` 或 `true` 时强制下载;默认内联展示 |

默认内联是因为 banner 图和公告的 html 都要直接渲染。

### 响应头

```
Content-Type: <附件的 content_type>
Content-Disposition: inline; filename*=UTF-8''%E5%85%AC%E5%91%8A.pdf
Cache-Control: public, max-age=31536000, immutable
ETag: "<checksum>"
```

文件名做 RFC 5987 编码 —— 线上文件名含中文、空格和全角括号,直接塞进头里
会被截断,甚至构造出额外的响应头。

内容按 id 不可变(改内容就是新 id),所以可以放心长缓存。

### 错误

| 状态码 | 什么时候 |
| --- | --- |
| `404` | id 不存在,或 id 格式就不合法(不打数据库直接判) |
| `404` | 元数据在但字节还没回填 —— 对客户端就是「还没有」,不是 500 |
