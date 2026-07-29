# Admin.AdminUserController

管理员账号。替代 core 的 `/admin/admin-user/*`。

`/me` 两个接口**登录即可**(运营也能改自己的档案);其余三个**只有
`role=admin` 能进**。

共通约定见 [../README](../README.md)。

---

## 管理员对象

```json
{
  "id": "3ke6kg3wk223e",
  "nickname": "运维小张",
  "email": null,
  "phone": "13900000001",
  "phone_region": "86",
  "role": "admin",
  "superuser": false,
  "avatar": null,
  "last_login_at": "2026-07-29T09:00:00.000000Z",
  "inserted_at": "2026-01-01T00:00:00.000000Z"
}
```

| 字段 | 说明 |
| --- | --- |
| `role` | `admin` 或 `operator` |
| `superuser` | 超管:不可删、不可降权。对应 core 的 `Special` |

> core 还有个 `Unknown = 0` 的角色值,那是没初始化的脏值,不迁。

管理员和 C 端用户是**两张完全独立的表** —— 管理员没有 DID,不在 PDS 上,
密码由 rice 自己保管。

---

## `GET /api/admin/me`

当前登录的管理员自己。登录即可。

响应 `200`,`data` 是管理员对象。

---

## `PATCH /api/admin/me`

改自己的档案。登录即可。

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `nickname` | string | 最长 64 |
| `avatar_id` | string | 附件 id |

**动不了角色和密码** —— 那两样各有各的入口。运营改不了自己的 `role`。

响应 `200`,`data` 是更新后的管理员对象。

---

## `GET /api/admin/admin_users`

管理员列表。**仅 `role=admin`。**

分页,见 [分页](../README.md#分页)。

响应 `200`,`data` 是管理员对象数组。软删的不在里面。

---

## `POST /api/admin/admin_users`

新建管理员。**仅 `role=admin`。**

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `phone` | string | **是** | 5–20 位数字 |
| `phone_region` | string | 否 | 默认 `86` |
| `email` | string | 否 | 联系方式,不能用来登录 |
| `nickname` | string | 否 | 最长 64 |
| `role` | string | 否 | `admin` 或 `operator`,默认 `operator` |
| `avatar_id` | string | 否 | |

**手机号必填。** 登录和找回密码都只走手机号,只填邮箱建出来的账号存得进库,
却既登不进去也找不回密码。数据库上也有 `phone is not null` 的约束,
免得 `mix rice.import` 之类绕过 changeset 的路径再写进这种账号。

### 响应 `201`

```json
{ "data": { "…管理员对象…", "initial_password": "aK3mPq7RtY9x" } }
```

`initial_password` 是随机生成的 12 位初始密码,**只有这一次能看到** ——
库里只有摘要。字母表去掉了容易看错的 `0` `O` `1` `l` `I`,这串要靠人念给
同事听。

### 错误

| 状态码 | body |
| --- | --- |
| `403` | 调用者是 `operator` |
| `422` | `{"errors":{"phone":["必须填手机号"]}}` |
| `422` | `{"errors":{"phone":["已被占用"]}}` |
| `422` | `{"errors":{"role":["只能是 admin 或 operator"]}}` |

---

## `DELETE /api/admin/admin_users/:id`

删管理员(软删)。**仅 `role=admin`。**

响应 `204`。同一个事务里**删掉他的全部令牌** —— 否则被删的人手上那把钥匙
还能用。

### 错误

| 状态码 | body |
| --- | --- |
| `403` | 调用者是 `operator` |
| `404` | 不存在 |
| `422` | `{"errors":{"detail":"超级管理员不能删除"}}` |
| `422` | `{"errors":{"detail":"不能删除自己"}}` |

软删的行留在库里(审计要指得到),但**不占用**手机号和邮箱 —— 唯一索引是
带 `where deleted_at is null` 的部分索引。

## 权限这层在服务端

core 的角色控制只是前端菜单上的一个 `hideInMenu: !adminAuth` —— 运营只要
知道路径就能调管理员管理的接口。rice 在路由上挂了 `require_admin_role`,
服务端强制。
