# PageController

## `GET /`

**不是 API。** 一个 HTML 落地页,渲染当前浏览器 session 里的 Semi 身份和
AT Protocol 身份,用来肉眼确认
[Semi 登录流程](semi_auth_controller.md)走通了。

没有参数,没有 JSON 响应,前端不调它。

登录流程真正的落点是前端应用,见
[semi_auth_controller](semi_auth_controller.md#get-callback)。
