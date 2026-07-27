defmodule RiceWeb.Api.AttachmentController do
  @moduledoc """
  附件读取与上传。

  **上传必须认证。** core 的 `/api/v1/file/upload` 标着 `AllowAnonymous` ——
  任何人都能往服务器写文件,没有身份、没有配额。这里由路由上的
  `require_authenticated_user` 拦住,并且大小和类型都在 `Rice.Files` 里校验。
  """
  use RiceWeb, :controller

  alias Rice.Files

  action_fallback RiceWeb.Api.FallbackController

  @doc "上传。需要登录;大小上限 20MB,content-type 走白名单。"
  def create(conn, %{"file" => %Plug.Upload{} = upload} = params) do
    kind = if params["kind"] in ["file"], do: "file", else: "image"

    with {:ok, content} <- File.read(upload.path),
         {:ok, attachment} <-
           Files.create_attachment(content, %{
             kind: kind,
             # 只取 basename:客户端可以在 filename 里塞路径
             filename: Path.basename(upload.filename || "unnamed"),
             content_type: upload.content_type
           }) do
      conn
      |> put_status(:created)
      |> put_view(json: RiceWeb.Api.AttachmentJSON)
      |> render(:show, attachment: attachment)
    else
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
      {:error, _reason} -> {:error, :unprocessable_entity}
    end
  end

  def create(conn, _params) do
    conn |> put_status(:unprocessable_entity) |> json(%{errors: %{file: ["缺少上传文件"]}})
  end

  def show(conn, %{"id" => id}) do
    with {:ok, attachment} <- Files.fetch_attachment(id),
         {:ok, content} <- read(attachment) do
      conn
      |> put_resp_content_type(attachment.content_type || "application/octet-stream", nil)
      |> put_resp_header("content-disposition", disposition(conn, attachment))
      # 附件内容按 id 不可变(改内容就是新 id),可以放心长缓存
      |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
      |> put_resp_header("etag", etag(attachment))
      |> send_resp(200, content)
    end
  end

  # 元数据在但字节还没回填 —— 对客户端就是"还没有",不是 500
  defp read(attachment) do
    case Files.read(attachment) do
      {:ok, content} -> {:ok, content}
      {:error, :not_stored} -> {:error, :not_found}
      other -> other
    end
  end

  # 默认内联展示(banner/公告 html 都要内联),`?download=1` 时才强制下载。
  # 文件名做 RFC 5987 编码 —— 线上文件名含中文、空格和全角括号,
  # 直接塞进头里会被截断甚至构造出额外的响应头。
  defp disposition(conn, attachment) do
    kind = if conn.params["download"] in ~w(1 true), do: "attachment", else: "inline"
    "#{kind}; filename*=UTF-8''#{URI.encode(attachment.filename, &URI.char_unreserved?/1)}"
  end

  defp etag(%{checksum: nil, id: id}), do: ~s("#{id}")
  defp etag(%{checksum: checksum}), do: ~s("#{checksum}")
end
