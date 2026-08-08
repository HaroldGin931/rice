defmodule Rice.Import.Writer do
  @moduledoc """
  导入的写入端。每张表的映射各写各的,插入、计数、外键解析这几段是共用的。
  """
  import Ecto.Query

  alias Rice.Repo

  @doc """
  `%{core 的 legacy_id => rice 的 TSID}`。

  外键一次查一个是 N+1:稻米流水两千多行,每行两个外键就是五千次往返。
  这几张表的行数都是运营级别的,整张读进内存做成 map 便宜得多。
  """
  def legacy_map(schema) do
    from(s in schema, where: not is_nil(s.legacy_id), select: {s.legacy_id, s.id})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  解析一个外键。返回 `{:ok, tsid}` / `{:ok, nil}`(源为空)/ `:error`(解析不到)。

  **解析不到是硬错误,不静默跳过** —— 一个解析不到的 user_id 意味着这条流水
  记在了谁头上是不确定的,悄悄写成 NULL 比报错更糟。
  """
  def resolve(map, legacy_id)
  def resolve(_map, nil), do: {:ok, nil}
  def resolve(_map, ""), do: {:ok, nil}
  # core 用全零 GUID 当"没有"的占位值(后台发放的 participator_id)
  def resolve(_map, "00000000-0000-0000-0000-000000000000"), do: {:ok, nil}

  def resolve(map, legacy_id) when is_binary(legacy_id) do
    case Map.fetch(map, legacy_id) do
      {:ok, id} -> {:ok, id}
      :error -> :error
    end
  end

  def resolve(_map, _), do: :error

  @doc """
  `resolve/2` 的 `insert_each` 版:解析不到就变成一条点名到列和行的 `{:skip, …}`。

  警告里带上是哪一列、哪一行 —— "解析不到"这种错误光知道有几条没用,
  得能顺着它回 MySQL 里把那一行找出来。
  """
  def fk(map, legacy_id, column, row_id) do
    case resolve(map, legacy_id) do
      {:ok, id} -> {:ok, id}
      :error -> {:skip, "#{column} = #{inspect(legacy_id)} 解析不到(行 #{row_id})"}
    end
  end

  @doc "MySQL 的 tinyint 过来是整数,但不同驱动版本上也见过布尔。"
  def truthy?(1), do: true
  def truthy?(true), do: true
  def truthy?(_), do: false

  @doc "core 的 NOT NULL DEFAULT '' 表示的是\"没有\";rice 里那是 NULL。"
  def blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def blank_to_nil(_), do: nil

  @doc """
  软删的时刻。core 只有一个 `deleted` 布尔,没记什么时候删的 ——
  拿 `updated_at` 当近似值,比填导入时刻诚实(那会让所有软删看起来都发生在今天)。
  """
  def deleted_at(row) do
    if truthy?(row["deleted"]), do: row["updated_at"] || row["created_at"], else: nil
  end

  @doc """
  把 core 的 `created_at` / `updated_at` 盖到 changeset 上。

  不照搬的话,所有历史数据的创建时间都会变成导入那一刻 —— 勋章、节点、提案的
  "创建时间"整列失真。这些字段不在各自 changeset 的 `cast` 列表里(它们本来就
  不该由调用方指定),所以这里用 `force_change`。

  顺带补齐微秒精度:MySQL 的 `datetime` 没有小数位,而这些列是
  `utc_datetime_usec`,`force_change` 不走 cast,精度不补齐 dump 会报错。
  """
  def keep_timestamps(changeset, row) do
    case to_usec(row["created_at"]) do
      nil ->
        changeset

      created ->
        changeset
        |> Ecto.Changeset.force_change(:inserted_at, created)
        |> Ecto.Changeset.force_change(:updated_at, to_usec(row["updated_at"]) || created)
    end
  end

  defp to_usec(%DateTime{} = dt), do: %{dt | microsecond: {elem(dt.microsecond, 0), 6}}
  defp to_usec(%NaiveDateTime{} = n), do: n |> DateTime.from_naive!("Etc/UTC") |> to_usec()
  defp to_usec(_), do: nil

  @doc """
  逐行建 changeset 再插入,返回 `%{inserted:, skipped:, warnings:}`。

  `build` 拿到一行,返回:

    * `{:ok, changeset}` —— 照常插入
    * `{:ok, changeset, 警告}` —— 插入,但这一行有需要人去核的地方。
      "导了但可疑"和"没导"是两件事,报告里得分得开:前者不影响行数对账,
      后者影响。只有 skip 一种出口的话,可疑行要么被迫丢掉、要么悄悄进库。
    * `{:skip, 警告}` —— 不插入

  `on_conflict: :nothing` 让重复跑是安全的,但**它不能告诉你有没有真的插进去**:
  Ecto 只在主键由数据库生成时才会把未插入的行的 id 置为 nil,而我们的 TSID 是
  应用侧生成的,所以返回的结构里 id 永远有值。一开始靠 `%{id: nil}` 判断,
  结果第二次跑仍然报"新增 21",而对账显示行数没变 —— 报告在说谎。

  改成插入前后各数一次:差值就是真实新增数,精确且与 Ecto 的实现细节无关。
  """
  def insert_each(rows, schema, build) do
    before_count = Repo.aggregate(schema, :count)

    acc =
      Enum.reduce(rows, %{attempted: 0, warnings: []}, fn row, acc ->
        case build.(row) do
          {:skip, warning} ->
            warn(acc, warning)

          {:ok, changeset} ->
            insert(acc, changeset)

          {:ok, changeset, warning} ->
            acc |> warn(warning) |> insert(changeset)
        end
      end)

    inserted = Repo.aggregate(schema, :count) - before_count
    %{inserted: inserted, skipped: length(rows) - inserted, warnings: acc.warnings}
  end

  defp insert(acc, changeset) do
    case Repo.insert(changeset, on_conflict: :nothing) do
      {:ok, _} -> %{acc | attempted: acc.attempted + 1}
      {:error, cs} -> warn(acc, inspect(cs.errors))
    end
  end

  defp warn(acc, warnings) when is_list(warnings), do: %{acc | warnings: acc.warnings ++ warnings}
  defp warn(acc, warning), do: %{acc | warnings: acc.warnings ++ [warning]}
end
