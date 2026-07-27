defmodule Rice.Content do
  @moduledoc """
  运营内容:应用入口、轮播位、公告。

  三者都是后台维护、C 端只读,没有用户维度,所以是整个迁移里依赖最少的一块 ——
  期 1 拿它来把 schema 约定、REST 风格和测试模板跑通。
  """
  import Ecto.Query

  alias Rice.Content.{Announcement, App, Banner}
  alias Rice.{Pagination, Repo}

  # ── 应用入口 ────────────────────────────────────────────────────────────

  @doc "按 position 升序列出所有应用。数量是个位数,不分页。"
  def list_apps do
    Repo.all(from a in App, order_by: [asc: a.position, asc: a.id], preload: [:logo])
  end

  # ── 轮播位 ──────────────────────────────────────────────────────────────

  @doc "按 position 升序列出所有 banner。"
  def list_banners do
    Repo.all(from b in Banner, order_by: [asc: b.position, asc: b.id], preload: [:image])
  end

  # ── 公告 ────────────────────────────────────────────────────────────────

  @doc "公告分页。新的在前。"
  def list_announcements(params \\ %{}) do
    from(a in Announcement, preload: [:attachment])
    |> Pagination.paginate(Repo, Pagination.params(params))
  end

  @doc "取单条公告。`{:ok, announcement}` 或 `{:error, :not_found}`。"
  def fetch_announcement(id) do
    if Rice.Tsid.valid?(id) do
      case Repo.get(from(a in Announcement, preload: [:attachment]), id) do
        nil -> {:error, :not_found}
        announcement -> {:ok, announcement}
      end
    else
      # 长度/字符不合法的 id 根本不可能存在,直接当 404,不去打数据库
      {:error, :not_found}
    end
  end
end
