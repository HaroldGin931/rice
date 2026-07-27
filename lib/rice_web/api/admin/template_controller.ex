defmodule RiceWeb.Api.Admin.TemplateController do
  @moduledoc """
  批量操作的 Excel 模板。core 是 `/admin/template/get`,返回两个裸 fileId;
  这里返回结构化的附件对象,前端不用自己拼下载地址。

  模板本身是运营上传的附件,id 放在配置里。
  """
  use RiceWeb, :controller

  def index(conn, _params) do
    cfg = Application.get_env(:rice, :templates, [])

    render(conn, :index,
      grain_distribution: attachment(cfg[:grain_distribution]),
      badge_distribution: attachment(cfg[:badge_distribution])
    )
  end

  # 没配或配了个不存在的 id 都返回 null,不是 500 —— 模板缺失不该让整个后台报错
  defp attachment(nil), do: nil

  defp attachment(id) do
    case Rice.Files.fetch_attachment(id) do
      {:ok, attachment} -> attachment
      {:error, _} -> nil
    end
  end
end
