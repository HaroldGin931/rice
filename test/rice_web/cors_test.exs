defmodule RiceWeb.CorsTest do
  @moduledoc """
  跨域。

  C 端 app 和 rice **从来不同源**(app 在 `xjdao.xyz`,rice 在 `rice.xjdao.xyz`),
  所以这不是开发期的方便,是 web 版能不能用的前提。原生 app 不走 CORS ——
  也就是说这个洞在真机上完全看不出来,只在浏览器里炸。
  """
  use RiceWeb.ConnCase, async: true

  @origin "http://localhost:8081"

  describe "预检" do
    test "OPTIONS 拿到放行的头,而不是 404", %{conn: conn} do
      conn =
        conn
        |> put_req_header("origin", @origin)
        |> put_req_header("access-control-request-method", "POST")
        |> put_req_header("access-control-request-headers", "content-type,authorization")
        |> options(~p"/api/session")

      assert conn.status in [200, 204]
      assert get_resp_header(conn, "access-control-allow-origin") == [@origin]

      [methods] = get_resp_header(conn, "access-control-allow-methods")
      assert methods =~ "POST"
    end

    # 令牌是靠 Authorization 头带的,这个头不放行的话每个认证请求都过不去
    test "放行 Authorization 头", %{conn: conn} do
      conn =
        conn
        |> put_req_header("origin", @origin)
        |> put_req_header("access-control-request-method", "GET")
        |> put_req_header("access-control-request-headers", "authorization")
        |> options(~p"/api/users/me")

      [headers] = get_resp_header(conn, "access-control-allow-headers")
      assert String.downcase(headers) =~ "authorization"
    end
  end

  describe "实际请求" do
    test "白名单里的来源拿得到放行头", %{conn: conn} do
      conn = conn |> put_req_header("origin", @origin) |> get(~p"/api/apps")

      assert json_response(conn, 200)
      assert get_resp_header(conn, "access-control-allow-origin") == [@origin]
    end

    # 白名单之外不该放行 —— 用 `*` 的话任何网页都能拿着用户浏览器里的令牌调这套 API
    test "不在白名单里的来源不放行", %{conn: conn} do
      conn = conn |> put_req_header("origin", "https://evil.example.com") |> get(~p"/api/apps")

      refute get_resp_header(conn, "access-control-allow-origin") == [
               "https://evil.example.com"
             ]

      refute get_resp_header(conn, "access-control-allow-origin") == ["*"]
    end
  end

  # `/session/:ticket` 自己写了一套 CORS 头。两边都写就会出现两个
  # Access-Control-Allow-Origin,浏览器直接判定不合法 —— 交接流程整个断掉。
  test "交接接口的 CORS 头没有被写成两份", %{conn: conn} do
    conn = conn |> put_req_header("origin", @origin) |> get(~p"/session/不存在的票")

    assert length(get_resp_header(conn, "access-control-allow-origin")) <= 1
  end

  # 开发环境用正则放行本机任意端口。写死端口的结果是:换个端口起前端,
  # 页面能打开、请求全被拦、界面一片空白,而且没有任何报错指向 CORS。
  test "白名单支持正则,不是只能写死字符串" do
    origins = Application.get_env(:rice, :cors)[:origins]
    Application.put_env(:rice, :cors, origins: [~r{^http://localhost(:\d+)?$}])
    on_exit(fn -> Application.put_env(:rice, :cors, origins: origins) end)

    for origin <- ["http://localhost:19006", "http://localhost:8081", "http://localhost"] do
      conn = build_conn() |> put_req_header("origin", origin) |> get(~p"/api/apps")
      assert get_resp_header(conn, "access-control-allow-origin") == [origin], origin
    end

    blocked = build_conn() |> put_req_header("origin", "http://evil.test") |> get(~p"/api/apps")
    refute get_resp_header(blocked, "access-control-allow-origin") == ["http://evil.test"]
  end

  describe "白名单解析" do
    test "逗号分隔,空格和空项都丢掉" do
      assert Rice.Cors.parse("https://a.com, https://b.com ,") ==
               ["https://a.com", "https://b.com"]
    end

    test "没配就是一个都不放行 —— 不猜域名" do
      assert Rice.Cors.parse("") == []
      assert Rice.Cors.parse(nil) == []
    end
  end
end
