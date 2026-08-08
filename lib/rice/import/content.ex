defmodule Rice.Import.Content do
  @moduledoc """
  期 1 的导入:附件元数据 + 应用 + 轮播 + 公告 + 全站配置。

  每张表都按 `legacy_id` 幂等 —— 反复跑只会补新增的行,支持"提前预导 → 切换日
  只跑增量"。外键通过 `attachments.legacy_id` 解析,解析不到的记为警告而不是静默跳过。

  事务和 dry-run 的回滚在 `Rice.Import` 里,这里只管映射。
  """
  import Ecto.Query
  import Rice.Import.Writer, only: [insert_each: 3, keep_timestamps: 2]

  alias Rice.Content.{Announcement, App, Banner}
  alias Rice.Files.Attachment
  alias Rice.Import.Source
  alias Rice.Repo
  alias Rice.Settings.{Document, Site}

  @doc "跑这几张表的导入,返回每张表的 `%{inserted:, skipped:, warnings:}`。"
  def import_all do
    %{
      attachments: import_attachments(),
      apps: import_apps(),
      banners: import_banners(),
      announcements: import_announcements(),
      site_settings: import_site_settings()
    }
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

  # core 没有附件表,fileId 散落在七处。漏掉任何一处的表现都一样:
  # 那一列的图片在 rice 里变成 null,而**行数对账完全看不出来**。
  # 先把它们收集去重,建出 attachments 行;文件本体的搬运是期 2。
  # 第三个元素是取哪些行。**必须和那张表实际导入的范围一致** ——
  # `t_proposal` 连软删一起导(它的软删行有投票和评论引用),所以收集也不能
  # 加 `deleted = 0`。第一版加了,结果 8 条软删提案的附件没被收进来,
  # 它们的 `attachment_id` 全是 null,而**每一项行数对账都是绿的**:
  # 提案 21 对 21,附件 78 对 78,少的是"关联"而不是"行"。
  @file_id_sources [
    {"t_app", "logo", "deleted = 0"},
    {"t_banner", "banner_file_id", "deleted = 0"},
    {"t_information", "attach_id", "deleted = 0"},
    {"t_admin_user", "avatar", "deleted = 0"},
    {"t_node", "logo", "deleted = 0"},
    {"t_medal", "attach_id", "deleted = 0"},
    {"t_proposal", "attach_id", "1 = 1"}
    # t_user_medal.attach_id 和 t_proposal.initiator_avatar 不收 —— 前者是
    # t_medal.attach_id 的副本,后者是 t_user.avatar 的副本。
    # t_user.avatar 在下面单独一路,因为它混着 PDS 的 blob URL。
  ]

  defp import_attachments do
    file_ids =
      (Enum.map(@file_id_sources, fn {table, column, filter} ->
         Source.query!("SELECT `#{column}` AS f FROM `#{table}` WHERE #{filter}")
       end) ++ [foundation_document_ids()])
      |> List.flatten()
      |> Enum.map(&extract_file_id/1)
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()

    # 用户头像单独一路。这一列存过两种东西:老的 fileId,和 PDS 的 blob URL。
    # 后者在 rice 里没有对应的附件,也不该有 —— 但它有一千多个,混进上面那批
    # 会给每一个都生成一条"无法解析"的警告,把真正需要看的警告冲掉。
    # 所以这里先按能不能解析分开,不能解析的只报一个总数。
    {avatars, unparsable} =
      Source.query!("SELECT avatar AS f FROM t_user")
      |> Enum.map(&extract_file_id/1)
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()
      |> Enum.split_with(&(Attachment.parse_legacy_id(&1) != :error))

    report = insert_each(Enum.uniq(file_ids ++ avatars), Attachment, &build_attachment/1)

    case unparsable do
      [] ->
        report

      list ->
        %{
          report
          | warnings:
              report.warnings ++
                [
                  "t_user.avatar 里有 #{length(list)} 个值不是 fileId(应为 PDS blob URL)," <>
                    "这些用户在 rice 里没有头像。例:#{inspect(Enum.take(list, 2))}"
                ]
        }
    end
  end

  defp build_attachment(file_id) do
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
    rows =
      Source.query!(
        "SELECT id, name, `desc`, logo, link, sort, created_at, updated_at FROM t_app WHERE deleted = 0"
      )

    insert_each(rows, App, fn row ->
      {:ok,
       %App{}
       |> App.changeset(%{
         legacy_id: row["id"],
         name: row["name"],
         description: row["desc"] || "",
         url: row["link"] || "",
         position: row["sort"] || 0,
         logo_id: attachment_id(row["logo"])
       })
       |> keep_timestamps(row)}
    end)
  end

  defp import_banners do
    rows =
      Source.query!(
        "SELECT id, banner_file_id, link_address, sort, created_at, updated_at " <>
          "FROM t_banner WHERE deleted = 0"
      )

    insert_each(rows, Banner, fn row ->
      {:ok,
       %Banner{}
       |> Banner.changeset(%{
         legacy_id: row["id"],
         url: row["link_address"] || "",
         position: row["sort"] || 0,
         image_id: attachment_id(row["banner_file_id"])
       })
       |> keep_timestamps(row)}
    end)
  end

  defp import_announcements do
    rows =
      Source.query!(
        "SELECT id, name, attach_id, sort, created_at, updated_at FROM t_information WHERE deleted = 0"
      )

    insert_each(rows, Announcement, fn row ->
      {:ok,
       %Announcement{}
       |> Announcement.changeset(%{
         legacy_id: row["id"],
         title: row["name"],
         position: row["sort"] || 0,
         attachment_id: attachment_id(row["attach_id"])
       })
       |> keep_timestamps(row)}
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
end
