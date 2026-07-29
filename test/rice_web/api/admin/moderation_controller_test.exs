defmodule RiceWeb.Api.Admin.ModerationControllerTest do
  @moduledoc "提案审核、勋章、全站配置、管理员账号。"
  use RiceWeb.ConnCase, async: true

  setup do
    {admin, token} = admin_with_token()
    %{admin: admin, token: token}
  end

  describe "提案审核" do
    test "列表看得到已下架的 —— C 端那份看不到", %{conn: conn, token: token} do
      author = user_fixture()
      listed = proposal_fixture(author)
      unlisted = proposal_fixture(author)
      Rice.Repo.update!(Ecto.Changeset.change(unlisted, listed: false))

      assert %{"data" => data} =
               conn |> authed(token) |> get(~p"/api/admin/proposals") |> json_response(200)

      ids = Enum.map(data, & &1["id"]) |> Enum.sort()
      assert ids == Enum.sort([listed.id, unlisted.id])

      # C 端只看得到上架的
      assert %{"data" => [one]} = build_conn() |> get(~p"/api/proposals") |> json_response(200)
      assert one["id"] == listed.id
    end

    test "下架和恢复", %{conn: conn, token: token} do
      proposal = proposal_fixture(user_fixture())

      assert %{"data" => %{"listed" => false}} =
               conn
               |> authed(token)
               |> patch(~p"/api/admin/proposals/#{proposal.id}", %{listed: false})
               |> json_response(200)

      assert %{"data" => []} = build_conn() |> get(~p"/api/proposals") |> json_response(200)

      # core 的 take-off 只能单向下架,没有恢复的入口
      assert %{"data" => %{"listed" => true}} =
               build_conn()
               |> authed(token)
               |> patch(~p"/api/admin/proposals/#{proposal.id}", %{listed: true})
               |> json_response(200)

      assert %{"data" => [_]} = build_conn() |> get(~p"/api/proposals") |> json_response(200)
    end

    test "listed 不是布尔值 422", %{conn: conn, token: token} do
      proposal = proposal_fixture(user_fixture())

      assert conn
             |> authed(token)
             |> patch(~p"/api/admin/proposals/#{proposal.id}", %{listed: "no"})
             |> json_response(422)
    end

    test "详情带评论,下架的也看得到", %{conn: conn, token: token} do
      author = user_fixture()
      proposal = proposal_fixture(author)
      Rice.Repo.update!(Ecto.Changeset.change(proposal, listed: false))
      {:ok, _} = Rice.Governance.create_comment(author, proposal, "一条评论")

      assert %{"data" => data} =
               conn
               |> authed(token)
               |> get(~p"/api/admin/proposals/#{proposal.id}")
               |> json_response(200)

      assert data["listed"] == false
      assert [%{"body" => "一条评论"}] = data["comments"]
    end

    test "能删任意评论,不只是自己的", %{conn: conn, token: token} do
      author = user_fixture()
      proposal = proposal_fixture(author)
      {:ok, comment} = Rice.Governance.create_comment(user_fixture(), proposal, "别人的评论")

      assert conn
             |> authed(token)
             |> delete(~p"/api/admin/proposals/#{proposal.id}/comments/#{comment.id}")
             |> response(204)

      assert %{"data" => []} =
               build_conn()
               |> get(~p"/api/proposals/#{proposal.id}/comments")
               |> json_response(200)
    end

    test "按标题和发起人搜", %{token: token} do
      author = user_fixture(%{nickname: "赵六"})
      target = proposal_fixture(author, %{title: "修路提案"})
      proposal_fixture(user_fixture(%{nickname: "钱七"}), %{title: "建桥提案"})

      for q <- ["修路", "赵六"] do
        assert %{"data" => [one]} =
                 build_conn()
                 |> authed(token)
                 |> get(~p"/api/admin/proposals?q=#{q}")
                 |> json_response(200)

        assert one["id"] == target.id
      end
    end
  end

  describe "勋章" do
    test "新建并列出,持有人数是现算的", %{conn: conn, token: token} do
      image = attachment_fixture(%{filename: "medal.png"})

      assert %{"data" => badge} =
               conn
               |> authed(token)
               |> post(~p"/api/admin/badges", %{name: "早期贡献者", image_id: image.id})
               |> json_response(201)

      assert badge["name"] == "早期贡献者"
      assert badge["image"]["filename"] == "medal.png"

      record = Rice.Repo.get!(Rice.Community.Badge, badge["id"])
      for _ <- 1..3, do: {:ok, _} = Rice.Community.award_badge(record, user_fixture())

      assert %{"data" => [listed]} =
               build_conn() |> authed(token) |> get(~p"/api/admin/badges") |> json_response(200)

      assert listed["holder_count"] == 3
    end

    test "持有人列表带联系方式,可按名字筛", %{conn: conn, token: token} do
      badge = badge_fixture()
      holder = user_fixture(%{nickname: "孙八", email: "sun@example.com"})
      {:ok, _} = Rice.Community.award_badge(badge, holder)
      {:ok, _} = Rice.Community.award_badge(badge, user_fixture(%{nickname: "周九"}))

      assert %{"data" => data} =
               conn
               |> authed(token)
               |> get(~p"/api/admin/badges/#{badge.id}/holders")
               |> json_response(200)

      assert length(data) == 2

      assert %{"data" => [one]} =
               build_conn()
               |> authed(token)
               |> get(~p"/api/admin/badges/#{badge.id}/holders?q=孙")
               |> json_response(200)

      assert one["email"] == "sun@example.com"
      assert one["awarded_at"]
    end
  end

  describe "全站配置" do
    test "读改一体 —— core 是三个接口改同一行", %{conn: conn, token: token} do
      a = attachment_fixture(%{filename: "章程.pdf"})
      b = attachment_fixture(%{filename: "年报.pdf"})

      assert %{"data" => data} =
               conn
               |> authed(token)
               |> patch(~p"/api/admin/settings", %{
                 fund_scale: 1_000_000,
                 proposal_approval_votes: 5,
                 document_ids: [a.id, b.id]
               })
               |> json_response(200)

      assert data["fund_scale"] == 1_000_000
      assert data["proposal_approval_votes"] == 5
      assert Enum.map(data["documents"], & &1["filename"]) == ["章程.pdf", "年报.pdf"]

      # 不传 document_ids 就不动文件清单
      assert %{"data" => data} =
               build_conn()
               |> authed(token)
               |> patch(~p"/api/admin/settings", %{fund_scale: 2_000_000})
               |> json_response(200)

      assert data["fund_scale"] == 2_000_000
      assert length(data["documents"]) == 2

      # 传空数组就是清空
      assert %{"data" => %{"documents" => []}} =
               build_conn()
               |> authed(token)
               |> patch(~p"/api/admin/settings", %{document_ids: []})
               |> json_response(200)
    end

    test "文件顺序就是数组顺序", %{conn: conn, token: token} do
      a = attachment_fixture(%{filename: "甲.pdf"})
      b = attachment_fixture(%{filename: "乙.pdf"})

      assert %{"data" => data} =
               conn
               |> authed(token)
               |> patch(~p"/api/admin/settings", %{document_ids: [b.id, a.id]})
               |> json_response(200)

      assert Enum.map(data["documents"], & &1["filename"]) == ["乙.pdf", "甲.pdf"]
    end

    test "负数 422", %{conn: conn, token: token} do
      assert conn
             |> authed(token)
             |> patch(~p"/api/admin/settings", %{fund_scale: -1})
             |> json_response(422)
    end

    test "改完 C 端立刻看得到", %{conn: conn, token: token} do
      conn
      |> authed(token)
      |> patch(~p"/api/admin/settings", %{fund_scale: 888})
      |> json_response(200)

      assert %{"data" => %{"fund_scale" => 888}} =
               build_conn() |> get(~p"/api/settings/foundation") |> json_response(200)
    end
  end

  describe "管理员账号(仅 role=admin)" do
    test "新建返回初始密码,而且这个密码能登进去", %{conn: conn, token: token} do
      assert %{"data" => created} =
               conn
               |> authed(token)
               |> post(~p"/api/admin/admin_users", %{
                 phone: "13911112222",
                 phone_region: "86",
                 role: "operator"
               })
               |> json_response(201)

      password = created["initial_password"]
      assert byte_size(password) == 12
      assert created["role"] == "operator"

      # 初始密码确实是这个账号的密码
      admin = Rice.Repo.get!(Rice.Admin.AdminUser, created["id"])
      assert Rice.Admin.AdminUser.valid_password?(admin, password)
      refute Rice.Admin.AdminUser.valid_password?(admin, password <> "x")
    end

    test "operator 进不了管理员管理 —— core 只在前端藏菜单", %{conn: conn} do
      {_operator, operator_token} = admin_with_token(%{role: "operator"})

      assert conn
             |> authed(operator_token)
             |> get(~p"/api/admin/admin_users")
             |> json_response(403)

      assert build_conn()
             |> authed(operator_token)
             |> post(~p"/api/admin/admin_users", %{phone: "13911113333"})
             |> json_response(403)
    end

    test "operator 照常能做内容运营", %{conn: conn} do
      {_operator, operator_token} = admin_with_token(%{role: "operator"})

      assert %{"data" => _} =
               conn
               |> authed(operator_token)
               |> post(~p"/api/admin/apps", %{name: "运营也能建"})
               |> json_response(201)
    end

    test "删不掉超管,也删不掉自己", %{conn: conn, token: token, admin: admin} do
      superuser = admin_fixture(%{superuser: true})
      Rice.Repo.update!(Ecto.Changeset.change(superuser, superuser: true))

      assert conn
             |> authed(token)
             |> delete(~p"/api/admin/admin_users/#{superuser.id}")
             |> json_response(422)

      assert build_conn()
             |> authed(token)
             |> delete(~p"/api/admin/admin_users/#{admin.id}")
             |> json_response(422)
    end

    test "删掉管理员会撤销他的全部会话", %{conn: conn, token: token} do
      {victim, victim_token} = admin_with_token()
      assert build_conn() |> authed(victim_token) |> get(~p"/api/admin/me") |> json_response(200)

      assert conn
             |> authed(token)
             |> delete(~p"/api/admin/admin_users/#{victim.id}")
             |> response(204)

      assert build_conn() |> authed(victim_token) |> get(~p"/api/admin/me") |> json_response(401)
    end

    test "手机号重复 422", %{conn: conn, token: token} do
      admin_fixture(%{phone: "13911114444", phone_region: "86"})

      assert conn
             |> authed(token)
             |> post(~p"/api/admin/admin_users", %{phone: "13911114444", phone_region: "86"})
             |> json_response(422)
    end

    # 登录和找回密码都只认手机号,只填邮箱建出来的账号是个死账号:
    # 能存进库,登不进去,也找不回密码。
    test "只填邮箱建不出管理员", %{conn: conn, token: token} do
      assert %{"errors" => errors} =
               conn
               |> authed(token)
               |> post(~p"/api/admin/admin_users", %{email: "no-phone@example.com"})
               |> json_response(422)

      assert errors["phone"]
      refute Rice.Repo.get_by(Rice.Admin.AdminUser, email: "no-phone@example.com")
    end

    test "邮箱仍然可以和手机号一起填", %{conn: conn, token: token} do
      assert %{"data" => created} =
               conn
               |> authed(token)
               |> post(~p"/api/admin/admin_users", %{
                 phone: "13911116666",
                 email: "both@example.com"
               })
               |> json_response(201)

      assert created["email"] == "both@example.com"
    end

    test "角色只能是 admin 或 operator", %{conn: conn, token: token} do
      assert conn
             |> authed(token)
             |> post(~p"/api/admin/admin_users", %{phone: "13911115555", role: "superadmin"})
             |> json_response(422)
    end
  end
end
