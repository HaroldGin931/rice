defmodule RiceWeb.Api.Admin.MiscControllerTest do
  @moduledoc "模板下载与贴文下架 —— 两个不落在 rice 自己数据上的接口。"
  use RiceWeb.ConnCase, async: false

  import Mox
  setup :verify_on_exit!

  setup do
    {_admin, token} = admin_with_token()
    %{token: token}
  end

  describe "模板" do
    test "配好了就返回结构化附件", %{conn: conn, token: token} do
      grain = attachment_fixture(%{filename: "稻米发放模板.xlsx"})
      Application.put_env(:rice, :templates, grain_distribution: grain.id)
      on_exit(fn -> Application.delete_env(:rice, :templates) end)

      assert %{"data" => data} =
               conn |> authed(token) |> get(~p"/api/admin/templates") |> json_response(200)

      assert data["grain_distribution"]["filename"] == "稻米发放模板.xlsx"
      assert data["grain_distribution"]["url"]
      assert data["badge_distribution"] == nil
    end

    # 模板没配是运营的事,不该让整个后台 500
    test "没配或配了个不存在的 id 都返回 null", %{conn: conn, token: token} do
      Application.put_env(:rice, :templates, grain_distribution: "2222222222222")
      on_exit(fn -> Application.delete_env(:rice, :templates) end)

      assert %{"data" => data} =
               conn |> authed(token) |> get(~p"/api/admin/templates") |> json_response(200)

      assert data["grain_distribution"] == nil
    end
  end

  describe "贴文下架" do
    setup do
      Application.put_env(:rice, :post_client, Rice.PostClientMock)
      on_exit(fn -> Application.delete_env(:rice, :post_client) end)
      :ok
    end

    test "下架就是打 blacklist 标签", %{conn: conn, token: token} do
      expect(Rice.PostClientMock, :label, fn "at://did:plc:x/app.bsky.feed.post/1",
                                             ["blacklist"] ->
        :ok
      end)

      assert conn
             |> authed(token)
             |> post(~p"/api/admin/post_takedowns", %{uri: "at://did:plc:x/app.bsky.feed.post/1"})
             |> response(204)
    end

    test "恢复就是清空标签", %{conn: conn, token: token} do
      expect(Rice.PostClientMock, :label, fn _uri, [] -> :ok end)

      assert conn
             |> authed(token)
             |> delete(~p"/api/admin/post_takedowns", %{
               uri: "at://did:plc:x/app.bsky.feed.post/1"
             })
             |> response(204)
    end

    test "缺 uri 422,不会去打 post 服务", %{conn: conn, token: token} do
      assert conn
             |> authed(token)
             |> post(~p"/api/admin/post_takedowns", %{})
             |> json_response(422)
    end

    test "post 服务出错时返回 502,不是 500", %{conn: conn, token: token} do
      expect(Rice.PostClientMock, :label, fn _, _ -> {:error, {:post_service, 500}} end)

      assert conn
             |> authed(token)
             |> post(~p"/api/admin/post_takedowns", %{uri: "at://x/y/1"})
             |> json_response(502)
    end

    test "未配置时 503", %{conn: conn, token: token} do
      expect(Rice.PostClientMock, :label, fn _, _ -> {:error, :post_service_not_configured} end)

      assert conn
             |> authed(token)
             |> post(~p"/api/admin/post_takedowns", %{uri: "at://x/y/1"})
             |> json_response(503)
    end

    test "未认证 401 —— 管理凭据留在服务端的意义就在这", %{conn: conn} do
      assert conn
             |> post(~p"/api/admin/post_takedowns", %{uri: "at://x/y/1"})
             |> json_response(401)
    end
  end

  @doc false
  # 后台的每一个列表都是页码式的(前端 13 个表格都走 ProTable)。
  # 逐个扫一遍:单元测试用的是最普通的查询,而真正会出问题的是那些带
  # group_by / join 的 —— 勋章列表就因为 group_by 在页码模式下 500 过。
  describe "每个后台列表在页码模式下都得能开" do
    setup %{conn: conn} do
      {admin, token} = admin_with_token()
      user = user_fixture()
      badge = badge_fixture()
      {:ok, _} = Rice.Community.award_badge(badge, user)
      {:ok, _} = Rice.Grains.grant(user, 10)
      proposal_fixture(user)

      %{conn: conn, token: token, admin: admin, user: user, badge: badge}
    end

    test "每一条都返回 200 且带 total", ctx do
      %{conn: conn, token: token, user: user, badge: badge} = ctx

      paths = [
        ~p"/api/admin/users?page=1&per_page=5",
        ~p"/api/admin/admin_users?page=1&per_page=5",
        ~p"/api/admin/proposals?page=1&per_page=5",
        ~p"/api/admin/badges?page=1&per_page=5",
        ~p"/api/admin/grain_grants?page=1&per_page=5",
        ~p"/api/admin/badges/#{badge.id}/holders?page=1&per_page=5",
        ~p"/api/admin/users/#{user.id}/grain_transfers?page=1&per_page=5"
      ]

      for path <- paths do
        assert %{"data" => data, "meta" => meta} =
                 build_conn() |> authed(token) |> get(path) |> json_response(200)

        assert is_list(data), "#{path} 没返回列表"
        assert is_integer(meta["total"]), "#{path} 的 meta 里没有 total"
        assert meta["page"] == 1
      end

      assert conn
    end
  end
end
