defmodule Rice.Import.Content do
  @moduledoc """
  期 1 的导入:附件元数据 + 应用 + 轮播 + 公告 + 全站配置。

  每张表都按 `legacy_id` 幂等 —— 反复跑只会补新增的行,支持"提前预导 → 切换日
  只跑增量"。外键通过 `attachments.legacy_id` 解析,解析不到的记为警告而不是静默跳过。
  """
  import Ecto.Query

  alias Rice.Content.{Announcement, App, Banner}
  alias Rice.Files.Attachment
  alias Rice.Import.Source
  alias Rice.Repo
  alias Rice.Settings.{Document, Site}

  @doc """
  跑一遍导入。`commit?` 为 false 时全部在一个会回滚的事务里执行 ——
  能得到真实的行数和冲突数,但什么都不留下。
  """
  def run(commit?) do
    fun = fn ->
      report = %{
        attachments: import_attachments(),
        apps: import_apps(),
        banners: import_banners(),
        announcements: import_announcements(),
        site_settings: import_site_settings()
      }

      # 对账必须在事务**内**算 —— dry-run 会回滚,回滚之后再数就全是 0,
      # 会得出"一条都没导进去"的错误结论。
      result = %{report: report, reconciliation: reconcile()}

      unless commit?, do: Repo.rollback({:dry_run, result})
      result
    end

    case Repo.transaction(fun, timeout: :timer.minutes(30)) do
      {:ok, result} -> {:ok, result}
      {:error, {:dry_run, result}} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  两边行数是否一致。附件不比 —— core 没有附件表,rice 这边是从四处的 fileId
  汇总去重出来的,数量本来就对不上。
  """
  def reconcile do
    for {mysql_table, name, schema} <- [
          {"t_app", "apps", App},
          {"t_banner", "banners", Banner},
          {"t_information", "announcements", Announcement}
        ] do
      source_count = Source.count!(mysql_table)
      target_count = Repo.aggregate(schema, :count)
      %{name: name, source: source_count, target: target_count, ok?: source_count == target_count}
    end
  end

  # ── 附件 ────────────────────────────────────────────────────────────────

  # core 没有附件表,fileId 散落在 t_app.logo / t_banner.banner_file_id /
  # t_information.attach_id / t_global_config.foundation_public_document 里。
  # 先把它们收集去重,建出 attachments 行;文件本体的搬运是期 2。
  defp import_attachments do
    file_ids =
      [
        Source.query!("SELECT logo AS f FROM t_app WHERE deleted = 0"),
        Source.query!("SELECT banner_file_id AS f FROM t_banner WHERE deleted = 0"),
        Source.query!("SELECT attach_id AS f FROM t_information WHERE deleted = 0"),
        foundation_document_ids()
      ]
      |> List.flatten()
      |> Enum.map(&extract_file_id/1)
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()

    insert_each(file_ids, Attachment, fn file_id ->
      case Attachment.parse_legacy_id(file_id) do
        {:ok, %{kind: kind, filename: filename}} ->
          {:ok,
           Attachment.changeset(%Attachment{}, %{
             legacy_id: file_id,
             kind: kind,
             filename: filename
           })}

        :error ->
          {:skip, "无法解析的 fileId: #{inspect(file_id)}"}
      end
    end)
  end

  defp extract_file_id(%{"f" => f}), do: f
  defp extract_file_id(f) when is_binary(f), do: f
  defp extract_file_id(_), do: nil

  defp foundation_document_ids do
    Source.query!("SELECT foundation_public_document AS d FROM t_global_config WHERE deleted = 0")
    |> Enum.flat_map(fn %{"d" => json} -> decode_documents(json) end)
  end

  defp decode_documents(nil), do: []

  defp decode_documents(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> Enum.filter(list, &is_binary/1)
      _ -> []
    end
  end

  defp decode_documents(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp decode_documents(_), do: []

  # ── 内容位 ──────────────────────────────────────────────────────────────

  defp import_apps do
    rows = Source.query!("SELECT id, name, `desc`, logo, link, sort FROM t_app WHERE deleted = 0")

    insert_each(rows, App, fn row ->
      {:ok,
       App.changeset(%App{}, %{
         legacy_id: row["id"],
         name: row["name"],
         description: row["desc"] || "",
         url: row["link"] || "",
         position: row["sort"] || 0,
         logo_id: attachment_id(row["logo"])
       })}
    end)
  end

  defp import_banners do
    rows =
      Source.query!(
        "SELECT id, banner_file_id, link_address, sort FROM t_banner WHERE deleted = 0"
      )

    insert_each(rows, Banner, fn row ->
      {:ok,
       Banner.changeset(%Banner{}, %{
         legacy_id: row["id"],
         url: row["link_address"] || "",
         position: row["sort"] || 0,
         image_id: attachment_id(row["banner_file_id"])
       })}
    end)
  end

  defp import_announcements do
    rows = Source.query!("SELECT id, name, attach_id, sort FROM t_information WHERE deleted = 0")

    insert_each(rows, Announcement, fn row ->
      {:ok,
       Announcement.changeset(%Announcement{}, %{
         legacy_id: row["id"],
         title: row["name"],
         position: row["sort"] || 0,
         attachment_id: attachment_id(row["attach_id"])
       })}
    end)
  end

  # ── 全站配置 ────────────────────────────────────────────────────────────

  defp import_site_settings do
    case Source.query!(
           "SELECT fund_scale, issue_points_scale, foundation_public_document, " <>
             "proposal_approval_votes FROM t_global_config WHERE deleted = 0 LIMIT 1"
         ) do
      [] ->
        %{inserted: 0, skipped: 0, warnings: ["t_global_config 没有可用行"]}

      [row] ->
        site_existed? = Repo.exists?(from(s in Site))

        site =
          Repo.one(from s in Site, limit: 1) ||
            Repo.insert!(
              Site.changeset(%Site{}, %{
                fund_scale: row["fund_scale"] || 0,
                issued_grain_scale: row["issue_points_scale"] || 0,
                proposal_approval_votes: row["proposal_approval_votes"] || 0
              })
            )

        docs = decode_documents(row["foundation_public_document"])

        result =
          docs
          |> Enum.with_index()
          |> insert_each(Document, fn {file_id, index} ->
            case attachment_id(file_id) do
              nil ->
                {:skip, "公开文件找不到对应附件: #{inspect(file_id)}"}

              attachment_id ->
                {:ok,
                 Document.changeset(%Document{}, %{
                   site_setting_id: site.id,
                   attachment_id: attachment_id,
                   position: index
                 })}
            end
          end)

        if site_existed?,
          do: %{result | skipped: result.skipped + 1},
          else: %{result | inserted: result.inserted + 1}
    end
  end

  # ── 公共 ────────────────────────────────────────────────────────────────

  defp attachment_id(nil), do: nil
  defp attachment_id(""), do: nil

  defp attachment_id(file_id) do
    Repo.one(from a in Attachment, where: a.legacy_id == ^file_id, select: a.id)
  end

  # `on_conflict: :nothing` 让重复跑是安全的,但**它不能告诉你有没有真的插进去**:
  # Ecto 只在主键由数据库生成时才会把未插入的行的 id 置为 nil,而我们的 TSID 是
  # 应用侧生成的,所以返回的结构里 id 永远有值。一开始靠 `%{id: nil}` 判断,
  # 结果第二次跑仍然报"新增 21",而对账显示行数没变 —— 报告在说谎。
  #
  # 改成插入前后各数一次:差值就是真实新增数,精确且与 Ecto 的实现细节无关。
  defp insert_each(rows, schema, build) do
    before_count = Repo.aggregate(schema, :count)

    acc =
      Enum.reduce(rows, %{attempted: 0, warnings: []}, fn row, acc ->
        case build.(row) do
          {:skip, warning} ->
            %{acc | warnings: acc.warnings ++ [warning]}

          {:ok, changeset} ->
            case Repo.insert(changeset, on_conflict: :nothing) do
              {:ok, _} -> %{acc | attempted: acc.attempted + 1}
              {:error, cs} -> %{acc | warnings: acc.warnings ++ [inspect(cs.errors)]}
            end
        end
      end)

    inserted = Repo.aggregate(schema, :count) - before_count
    %{inserted: inserted, skipped: length(rows) - inserted, warnings: acc.warnings}
  end
end
