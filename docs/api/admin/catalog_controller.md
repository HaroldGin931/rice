# Admin.CatalogController

应用入口 / 轮播位 / 公告 / 节点的后台增删改排序。

替代 core 的 `/admin/app/*`、`/admin/banner/*`、`/admin/information/*`、
`/admin/node/*` —— **4 × 6 = 24 个动词式接口**,内容基本重复。

这里是 4 组 REST 路由指向同一个控制器。资源类型和响应视图由路由的 `assigns`
指定 —— 不从 URL 参数推,免得把用户输入喂给 `String.to_existing_atom/1`。

**登录即可**,运营也能做内容运营。

共通约定见 [../README](../README.md)。

---

## 四组路由

把下表的 `{资源}` 换成 `apps` / `banners` / `announcements` / `nodes`:

| 方法 | 路径 | 动作 |
| --- | --- | --- |
| `GET` | `/api/admin/{资源}` | 列表 |
| `POST` | `/api/admin/{资源}` | 新建 |
| `PUT` | `/api/admin/{资源}/positions` | 整体重排 |
| `GET` | `/api/admin/{资源}/:id` | 详情 |
| `PATCH` | `/api/admin/{资源}/:id` | 修改 |
| `DELETE` | `/api/admin/{资源}/:id` | 删除 |

> `/positions` 在路由里排在 `/:id` **前面**,否则 `"positions"` 会被当成一个 id。

---

## 各资源的字段

新建和修改共用同一组字段。`PATCH` 只改传了的。

### `apps`

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `name` | string | 是 | 最长 256 |
| `description` | string | 否 | |
| `url` | string | 否 | |
| `position` | integer | 否 | 不传则排到最后 |
| `logo_id` | string | 否 | 附件 id |

### `banners`

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `url` | string | 否 | 点击跳转目标,最长 512 |
| `position` | integer | 否 | |
| `image_id` | string | 否 | 图片附件 id |

### `announcements`

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `title` | string | 是 | 最长 128 |
| `position` | integer | 否 | |
| `attachment_id` | string | 否 | 正文,一个 html 附件 |

### `nodes`

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `name` | string | 是 | 最长 64 |
| `description` | string | 否 | |
| `position` | integer | 否 | |
| `user_id` | string | 否 | 节点主的 rice id |
| `logo_id` | string | 否 | |

---

## 响应

列表 `200` —— 不分页,按 `position` 升序,同位置按 id:

```json
{ "data": [ { "id": "…", "position": 0, "…": "…" } ] }
```

详情 / 新建 / 修改 —— `{"data": { … }}`,新建是 `201`。

后台的对象比 C 端那份多一个 `inserted_at`,`apps` / `banners` /
`announcements` / `nodes` 各自的字段和
[C 端文档](../app_controller.md)里的一致。

删除 `204`。

| 状态码 | 什么时候 |
| --- | --- |
| `401` | 没令牌 |
| `404` | id 不存在或格式不合法 |
| `422` | 校验失败 |

### 新建的位置

不传 `position` 时排到**最后**。core 是新的排最前,但后台列表本来就是拖拽
排序的,追加到末尾更符合「我刚加了一个」的直觉。

---

## `PUT /api/admin/{资源}/positions`

整份顺序覆盖。

```json
{ "ids": ["3ke6kg3wk223e", "3ke6kg3wk1abc", "3ke6kg3wk0xyz"] }
```

数组顺序即位置:第 0 个的 `position` 是 0,以此类推。**没出现在数组里的记录
不动。**

### 响应 `200`

重排后的完整列表(和 `GET` 同形)。

### 错误

| 状态码 | body |
| --- | --- |
| `422` | `{"errors":{"ids":["需要一个 id 数组"]}}` |
| `422` | `{"errors":{"ids":["这些 id 不存在: …"]}}` |

列表里有不存在的 id 就**整体报错**,不静默吞掉笔误。

core 的 `/sort` 也是整份覆盖,但一条条更新;这里在**一个事务**里做,
不会留下排到一半的顺序。
