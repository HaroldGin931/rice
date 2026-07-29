defmodule RiceWeb.Api.Admin.GrainControllerTest do
  use RiceWeb.ConnCase, async: true

  setup do
    {_admin, token} = admin_with_token()
    %{token: token}
  end

  describe "发放" do
    test "发给一个人", %{conn: conn, token: token} do
      user = user_fixture(%{phone: "13800002222", phone_region: "86"})

      assert %{"data" => %{"granted" => 1}} =
               conn
               |> authed(token)
               |> post(~p"/api/admin/grain_grants", %{
                 to: ["13800002222"],
                 amount: 100,
                 memo: "补贴"
               })
               |> json_response(201)

      assert Rice.Repo.get!(Rice.Accounts.User, user.id).grain_balance == 100
    end

    test "收款人可以用邮箱 / handle / DID / id", %{conn: conn, token: token} do
      a = user_fixture(%{email: "a@example.com"})
      b = user_fixture(%{handle: "bb.web5.xjdao.test"})
      c = user_fixture()

      assert %{"data" => %{"granted" => 3}} =
               conn
               |> authed(token)
               |> post(~p"/api/admin/grain_grants", %{
                 to: ["a@example.com", "bb.web5.xjdao.test", c.did],
                 amount: 10
               })
               |> json_response(201)

      for user <- [a, b, c] do
        assert Rice.Repo.get!(Rice.Accounts.User, user.id).grain_balance == 10
      end
    end

    # core 也是全有或全无,但它是在拿到分布式锁之后才发现数量对不上
    test "有一个收款人认不出来,整批都不发", %{conn: conn, token: token} do
      user = user_fixture(%{phone: "13800003333", phone_region: "86"})

      assert %{"errors" => %{"to" => [message]}} =
               conn
               |> authed(token)
               |> post(~p"/api/admin/grain_grants", %{
                 to: ["13800003333", "查无此人@example.com"],
                 amount: 50
               })
               |> json_response(422)

      assert message =~ "查无此人@example.com"
      assert Rice.Repo.get!(Rice.Accounts.User, user.id).grain_balance == 0
    end

    test "重复的收款人只发一次", %{conn: conn, token: token} do
      user = user_fixture(%{phone: "13800004444", phone_region: "86"})

      assert %{"data" => %{"granted" => 1}} =
               conn
               |> authed(token)
               |> post(~p"/api/admin/grain_grants", %{
                 to: ["13800004444", "13800004444", user.did],
                 amount: 25
               })
               |> json_response(201)

      assert Rice.Repo.get!(Rice.Accounts.User, user.id).grain_balance == 25
    end

    test "金额非法 422", %{conn: conn, token: token} do
      user = user_fixture()

      for amount <- [0, -1, "abc", nil, 1.5] do
        assert conn
               |> authed(token)
               |> post(~p"/api/admin/grain_grants", %{to: [user.did], amount: amount})
               |> json_response(422)
      end

      assert Rice.Repo.get!(Rice.Accounts.User, user.id).grain_balance == 0
    end

    test "收款人为空 422", %{conn: conn, token: token} do
      assert conn
             |> authed(token)
             |> post(~p"/api/admin/grain_grants", %{to: [], amount: 10})
             |> json_response(422)
    end

    # `to` 是 JSON 数组,里面塞什么都能过 HTTP 那一层。
    # 直接 String.trim/1 会抛,表现是 500 —— 客户端发错格式不该是服务端的错。
    test "收款人不是字符串时 422 而不是 500", %{conn: conn, token: token} do
      user = user_fixture()

      for bad <- [[nil], [123], [%{"phone" => "13800000000"}], [["嵌套"]], [user.did, nil]] do
        assert %{"errors" => %{"to" => [_]}} =
                 conn
                 |> authed(token)
                 |> post(~p"/api/admin/grain_grants", %{to: bad, amount: 10})
                 |> json_response(422)
      end

      assert Rice.Repo.get!(Rice.Accounts.User, user.id).grain_balance == 0
    end

    # 从表格里粘一列手机号,末尾常带几个空行
    test "空白的收款人直接丢掉,不算作认不出来", %{conn: conn, token: token} do
      user = user_fixture(%{phone: "13800006666", phone_region: "86"})

      assert %{"data" => %{"granted" => 1}} =
               conn
               |> authed(token)
               |> post(~p"/api/admin/grain_grants", %{
                 to: ["13800006666", "", "  "],
                 amount: 15
               })
               |> json_response(201)

      assert Rice.Repo.get!(Rice.Accounts.User, user.id).grain_balance == 15
    end

    test "全是空白就等于没有收款人", %{conn: conn, token: token} do
      assert conn
             |> authed(token)
             |> post(~p"/api/admin/grain_grants", %{to: ["", "  "], amount: 10})
             |> json_response(422)
    end

    test "停用的用户收不到", %{conn: conn, token: token} do
      user = user_fixture(%{phone: "13800005555", phone_region: "86"})
      Rice.Repo.update!(Ecto.Changeset.change(user, disabled_at: DateTime.utc_now()))

      assert conn
             |> authed(token)
             |> post(~p"/api/admin/grain_grants", %{to: ["13800005555"], amount: 10})
             |> json_response(422)
    end

    test "发放后账本自洽", %{conn: conn, token: token} do
      a = user_fixture()
      b = user_fixture()

      conn
      |> authed(token)
      |> post(~p"/api/admin/grain_grants", %{to: [a.did, b.did], amount: 70})
      |> json_response(201)

      assert Rice.Grains.reconcile().ok?
    end
  end

  describe "记录" do
    test "发放记录带收款人的联系方式", %{conn: conn, token: token} do
      user = user_fixture(%{nickname: "王五", email: "wangwu@example.com"})
      {:ok, _} = Rice.Grains.grant(user, 30)

      assert %{"data" => [one]} =
               conn |> authed(token) |> get(~p"/api/admin/grain_grants") |> json_response(200)

      assert one["amount"] == 30
      assert one["to"]["nickname"] == "王五"
      assert one["to"]["email"] == "wangwu@example.com"
    end

    test "按收款人筛", %{conn: conn, token: token} do
      wang = user_fixture(%{nickname: "王五"})
      li = user_fixture(%{nickname: "李四"})
      {:ok, _} = Rice.Grains.grant(wang, 10)
      {:ok, _} = Rice.Grains.grant(li, 20)

      assert %{"data" => [one]} =
               conn |> authed(token) |> get(~p"/api/admin/grain_grants?q=王") |> json_response(200)

      assert one["to"]["nickname"] == "王五"
    end

    # 手滑的日期不该让整个列表 500
    test "时间参数解析不了就当没传", %{conn: conn, token: token} do
      {:ok, _} = Rice.Grains.grant(user_fixture(), 10)

      assert %{"data" => [_]} =
               conn
               |> authed(token)
               |> get(~p"/api/admin/grain_grants?since=不是时间")
               |> json_response(200)
    end

    test "某人的明细,方向按那个人算而不是按管理员", %{conn: conn, token: token} do
      payer = user_fixture()
      payee = user_fixture()
      {:ok, _} = Rice.Grains.grant(payer, 100)
      {:ok, _} = Rice.Grains.transfer(payer, payee.did, 30)

      assert %{"data" => data} =
               conn
               |> authed(token)
               |> get(~p"/api/admin/users/#{payer.id}/grain_transfers")
               |> json_response(200)

      by_kind = Map.new(data, &{&1["kind"], &1["direction"]})
      assert by_kind["grant"] == "in"
      assert by_kind["gift"] == "out"
    end
  end

  test "未认证 401", %{conn: conn} do
    assert conn |> get(~p"/api/admin/grain_grants") |> json_response(401)

    assert build_conn()
           |> post(~p"/api/admin/grain_grants", %{to: ["x"], amount: 1})
           |> json_response(401)
  end
end
