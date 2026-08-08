defmodule Rice.Import.Writer do
  @moduledoc """
  导入的写入端。每张表的映射各写各的,插入和计数这一段是共用的。
  """
  alias Rice.Repo

  @doc """
  逐行建 changeset 再插入,返回 `%{inserted:, skipped:, warnings:}`。

  `build` 拿到一行,返回 `{:ok, changeset}` 或 `{:skip, 警告}`。

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
