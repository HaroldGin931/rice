# LegacyAttachmentController

历史治理正文图片的只读地址兼容。

`GET /api/v1/file/download?fileId=<32位十六进制GUID>&fileType=1`

- `fileType` 仅 `1`（图片）或 `2`（文件）。GUID 大小写均可。
- 按已有附件 `legacy_id` 的类型和 GUID 前缀查询；只有唯一匹配才读取。
- 缺少参数、非法参数、无匹配或多条匹配均返回 `404`。
- 复用原附件读取的类型、下载处置、缓存、ETag 和安全响应头；不提供上传或写入。
- 历史正文中的绝对旧下载 URL 在前端阅读时改为本站相对地址，原文文件保持不变。
