defmodule RiceWeb.Api.AttachmentJSON do
  @moduledoc "附件在各处响应里的内嵌形状。"

  alias Rice.Files.Attachment

  def show(%{attachment: attachment}), do: %{data: embed(attachment)}

  @doc "附件的紧凑表示。没有附件时是 null,不是空对象。"
  def embed(nil), do: nil
  def embed(%Ecto.Association.NotLoaded{}), do: nil

  def embed(%Attachment{} = a) do
    %{
      id: a.id,
      kind: a.kind,
      filename: a.filename,
      content_type: a.content_type,
      byte_size: a.byte_size,
      # 期 2 上线附件读取后,这个 URL 才真正可用;在那之前前端仍走 core 的
      # /api/v1/file/download。见 docs/backend-migration-plan.md §9。
      url: "/api/attachments/#{a.id}"
    }
  end
end
