defmodule Rice.Import.Source do
  @moduledoc """
  导入源:core 的 MySQL。用一个独立的短连接,不复用 `Rice.DaoSql` ——
  那条连接是给运行时的 Semi 桥用的,不该被一次性的导入任务占着。
  """

  @doc "连上 MySQL。`url` 形如 `mysql://user:pass@host:3306/xiangjiandao`。"
  def start_link(url) do
    opts =
      url
      |> parse_url()
      |> Keyword.merge(name: __MODULE__, pool_size: 1)

    MyXQL.start_link(opts)
  end

  @doc "查询,返回 map 列表(列名转成字符串键)。"
  def query!(sql, params \\ []) do
    %MyXQL.Result{columns: columns, rows: rows} = MyXQL.query!(__MODULE__, sql, params)
    Enum.map(rows || [], fn row -> columns |> Enum.zip(row) |> Map.new() end)
  end

  def count!(table) do
    [%{"c" => c}] = query!("SELECT COUNT(*) AS c FROM `#{table}` WHERE deleted = 0")
    c
  end

  defp parse_url(url) do
    %URI{host: host, port: port, path: path, userinfo: userinfo} = URI.parse(url)
    [username, password] = split_userinfo(userinfo)

    [
      hostname: host,
      port: port || 3306,
      username: username,
      password: password,
      database: String.trim_leading(path || "", "/")
    ]
  end

  defp split_userinfo(nil), do: ["root", ""]

  defp split_userinfo(userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [u, p] -> [URI.decode(u), URI.decode(p)]
      [u] -> [URI.decode(u), ""]
    end
  end
end
