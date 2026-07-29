# Admin.TemplateController

批量操作的 Excel 模板。**登录即可**。

替代 core 的 `/admin/template/get`。

共通约定见 [../README](../README.md)。

---

## `GET /api/admin/templates`

### 响应 `200`

```json
{
  "data": {
    "grain_distribution": {
      "id": "3ke6kg3wk223e",
      "kind": "file",
      "filename": "稻米发放模板.xlsx",
      "content_type": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      "byte_size": 8192,
      "url": "/api/attachments/3ke6kg3wk223e"
    },
    "badge_distribution": null
  }
}
```

core 返回的是两个**裸 fileId**,前端得自己拼下载地址。这里返回结构化的附件对象。

模板本身是一个附件,id 放在配置里:

```elixir
config :rice, :templates,
  grain_distribution: "3ke6kg3wk223e",
  badge_distribution: "3ke6kg3wk1abc"
```

没配、或者配了个不存在的 id,那一项就是 `null` —— 不是 500。模板缺失不该让
整个后台报错。

### 模板现在传不上来

`POST /api/attachments` 的 content-type 白名单里**没有 xlsx**
(见 [attachment_controller](../attachment_controller.md#限制))。也就是说
换一版模板没法从 rice 走,只能靠 `mix rice.import` 带进来或直接写库。

core 那边上传**完全不校验类型**,所以没这个问题 —— 这是 rice 收紧白名单时
连带出来的。要支持的话,把
`application/vnd.openxmlformats-officedocument.spreadsheetml.sheet`
加进 `Rice.Files` 的 `file` 白名单即可。

## 谁消费这些模板

`grain_distribution` 给批量发放稻米用。**解析 Excel 是前端的事** ——
[`POST /api/admin/grain_grants`](grain_controller.md) 收的是一个收款人数组,
服务端不该为了一个功能长出一个表格解析器。

`badge_distribution` 目前没有对应的接口 —— core 那边也没有,见
[badge_controller](badge_controller.md#发放勋章)。
