defmodule Rice.FakeImportSource do
  @moduledoc """
  假的 `Rice.Import.Source`,让导入能在没有 MySQL 的情况下跑完整条链路。

  行数据放在**测试进程的 process dictionary** 里 —— 导入是在测试进程里同步跑的,
  这样不同测试之间天然隔离,不需要 Agent 也不怕并发。

  只认导入代码实际会发的那几种 SQL:`SELECT … FROM t_x [WHERE …]`、
  `SELECT COUNT(*) …`、`SELECT COUNT(*), SUM(score) …`、以及抽样用的 `id IN (?)`。
  谓词也只实现用到的那几个。这不是一个 SQL 引擎,写成通用的反而会把真正的
  断言埋进解析逻辑里。
  """

  @doc "把某张 core 表的行装进当前测试进程。"
  def put(table, rows), do: Process.put({__MODULE__, table}, rows)

  @doc "当前测试进程里某张表的行。"
  def rows(table), do: Process.get({__MODULE__, table}, [])

  def query!(sql, params \\ []) do
    table = table_of(sql)
    rows = rows(table) |> apply_predicates(sql, params)

    cond do
      String.contains?(sql, "COUNT(*)") and String.contains?(sql, "SUM(score)") ->
        [%{"c" => length(rows), "s" => Enum.reduce(rows, 0, &(&1["score"] + &2))}]

      String.contains?(sql, "COUNT(*)") ->
        [%{"c" => length(rows)}]

      true ->
        project(rows, sql)
    end
  end

  # 附件收集用的是 `SELECT logo AS f FROM …`,真的驱动回来的是 %{"f" => …}。
  # 不实现列别名的话这些查询会静悄悄地全部返回 nil,附件一条都建不出来 ——
  # 而那正是这套测试要盯的东西之一。
  defp project(rows, sql) do
    case Regex.run(~r/SELECT\s+`?(\w+)`?\s+AS\s+(\w+)\s+FROM/i, sql) do
      [_, column, alias_] -> Enum.map(rows, &%{alias_ => &1[column]})
      nil -> rows
    end
  end

  def count!(table) do
    [%{"c" => c}] = query!("SELECT COUNT(*) AS c FROM `#{table}` WHERE deleted = 0")
    c
  end

  defp table_of(sql) do
    [_, table] = Regex.run(~r/FROM\s+`?(t_\w+)`?/, sql)
    table
  end

  defp apply_predicates(rows, sql, params) do
    rows
    |> filter_if(String.contains?(sql, "deleted = 0"), &(&1["deleted"] != 1))
    |> filter_if(String.contains?(sql, "phone <> ''"), &(&1["phone"] not in [nil, ""]))
    |> filter_if(String.contains?(sql, "role IN (1, 2)"), &(&1["role"] in [1, 2]))
    |> filter_if(String.contains?(sql, "id IN ("), &(&1["id"] in params))
    |> limit_if(String.contains?(sql, "LIMIT 1"))
  end

  defp filter_if(rows, false, _fun), do: rows
  defp filter_if(rows, true, fun), do: Enum.filter(rows, fun)

  defp limit_if(rows, false), do: rows
  defp limit_if(rows, true), do: Enum.take(rows, 1)
end
