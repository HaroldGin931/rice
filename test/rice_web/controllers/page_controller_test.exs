defmodule RiceWeb.PageControllerTest do
  use RiceWeb.ConnCase

  # 首页是 Semi 登录的调试页(f168843 换掉了 Phoenix 生成器的默认页),
  # 这里断言的是实际内容,不是生成器模板。
  test "GET / 渲染 Semi 登录页", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ "Semi"
    assert html =~ ~s|href="/login"|
  end
end
