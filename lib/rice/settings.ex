defmodule Rice.Settings do
  @moduledoc "全站配置(原 t_global_config)。单行。"
  import Ecto.Query

  alias Rice.Repo
  alias Rice.Settings.Site

  @doc """
  取全站配置。库里没有行时返回一个全零的默认值,而不是 nil ——
  这样 `GET /api/settings/foundation` 在全新部署上也是 200 而不是 500。
  """
  def get_site do
    Repo.one(from s in Site, limit: 1, preload: [documents: :attachment]) ||
      %Site{documents: []}
  end
end
