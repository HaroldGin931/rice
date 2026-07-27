defmodule Rice.Pagination do
  @moduledoc """
  Keyset(游标)分页,替掉 core 的 `PagedData{pageIndex, pageSize, total}`。

  用 TSID 主键当游标 —— 字典序即时间序,所以 `id < cursor` 就是"更早的那一页",
  不需要 `OFFSET`(深翻页会全表扫),也不需要 `COUNT(*)`(列表页基本用不上,
  而且在大表上是最贵的一次查询)。

      %{entries: [...], next_cursor: "3ke6kg3wk223e" | nil}

  默认按 id 倒序(新的在前)。`order: :asc` 用于 position 排序的内容位。
  """
  import Ecto.Query

  @default_limit 20
  @max_limit 100

  @type opts :: [limit: pos_integer(), before: String.t() | nil, after: String.t() | nil]

  @doc "从请求参数里解析出分页选项。非法输入一律退回默认值,不报错。"
  @spec params(map()) :: %{
          limit: pos_integer(),
          before: String.t() | nil,
          after: String.t() | nil
        }
  def params(params) when is_map(params) do
    %{
      limit: parse_limit(params["limit"]),
      before: parse_cursor(params["before"]),
      after: parse_cursor(params["after"])
    }
  end

  @doc "把分页条件套到 query 上。多取一条用来判断还有没有下一页。"
  @spec paginate(Ecto.Query.t(), Ecto.Repo.t(), map(), keyword()) :: %{
          entries: list(),
          next_cursor: String.t() | nil
        }
  def paginate(query, repo, %{limit: limit} = opts, config \\ []) do
    order = Keyword.get(config, :order, :desc)

    entries =
      query
      |> apply_cursor(opts, order)
      |> apply_order(order)
      |> limit(^(limit + 1))
      |> repo.all()

    case Enum.split(entries, limit) do
      {page, []} -> %{entries: page, next_cursor: nil}
      {page, _more} -> %{entries: page, next_cursor: page |> List.last() |> Map.fetch!(:id)}
    end
  end

  defp apply_cursor(query, %{before: nil, after: nil}, _order), do: query

  defp apply_cursor(query, %{before: cursor}, _order) when is_binary(cursor),
    do: from(q in query, where: q.id < ^cursor)

  defp apply_cursor(query, %{after: cursor}, _order) when is_binary(cursor),
    do: from(q in query, where: q.id > ^cursor)

  defp apply_order(query, :desc), do: from(q in query, order_by: [desc: q.id])
  defp apply_order(query, :asc), do: from(q in query, order_by: [asc: q.id])

  defp parse_limit(nil), do: @default_limit

  defp parse_limit(value) when is_integer(value), do: clamp(value)

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> clamp(n)
      _ -> @default_limit
    end
  end

  defp parse_limit(_), do: @default_limit

  defp clamp(n) when n < 1, do: @default_limit
  defp clamp(n) when n > @max_limit, do: @max_limit
  defp clamp(n), do: n

  # 非法游标当作"没传",而不是 500 —— 游标是不透明串,客户端不该猜它的结构,
  # 传坏了退回第一页比报错更合理。
  defp parse_cursor(value) when is_binary(value) do
    if Rice.Tsid.valid?(value), do: value, else: nil
  end

  defp parse_cursor(_), do: nil

  def default_limit, do: @default_limit
  def max_limit, do: @max_limit
end
