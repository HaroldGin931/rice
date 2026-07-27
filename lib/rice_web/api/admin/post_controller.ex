defmodule RiceWeb.Api.Admin.PostController do
  @moduledoc """
  贴文下架 / 恢复。贴文不在 rice 库里,这里只是把请求转给 post 服务 ——
  意义在于管理凭据不必下发到前端。

  用 uri 作为资源标识,所以放在 body 里而不是路径上:AT URI 里有斜杠。
  """
  use RiceWeb, :controller

  alias Rice.Admin.Posts

  action_fallback RiceWeb.Api.FallbackController

  def create(conn, %{"uri" => uri}) do
    handle(conn, Posts.take_down(uri))
  end

  def create(conn, _), do: missing_uri(conn)

  def delete(conn, %{"uri" => uri}) do
    handle(conn, Posts.restore(uri))
  end

  def delete(conn, _), do: missing_uri(conn)

  defp handle(conn, :ok), do: send_resp(conn, :no_content, "")

  defp handle(conn, {:error, :invalid_uri}), do: missing_uri(conn)

  defp handle(conn, {:error, :post_service_not_configured}) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{errors: %{detail: "贴文服务未配置"}})
  end

  defp handle(conn, {:error, reason}) do
    conn
    |> put_status(:bad_gateway)
    |> json(%{errors: %{detail: "贴文服务返回错误: #{inspect(reason)}"}})
  end

  defp missing_uri(conn) do
    conn |> put_status(:unprocessable_entity) |> json(%{errors: %{uri: ["缺少贴文 uri"]}})
  end
end
