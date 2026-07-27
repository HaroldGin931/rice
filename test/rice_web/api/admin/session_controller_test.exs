defmodule RiceWeb.Api.Admin.SessionControllerTest do
  use RiceWeb.ConnCase, async: true

  import Mox
  setup :verify_on_exit!

  alias Rice.Accounts.VerificationCode

  defp seed_code(target, purpose) do
    code = VerificationCode.generate_code()
    Rice.Repo.insert!(VerificationCode.build("sms", target, purpose, code))
    code
  end

  describe "两步登录" do
    setup do
      %{admin: admin_fixture(%{phone: "13900000001", phone_region: "86"})}
    end

    test "密码对了才发验证码", %{conn: conn} do
      expect(Rice.NotificationsMock, :send_sms, fn "86", "13900000001", _text -> :ok end)

      assert conn
             |> post(~p"/api/admin/session/challenge", %{
               phone: "13900000001",
               phone_region: "86",
               password: "admin-password"
             })
             |> response(202)

      assert Rice.Repo.get_by(VerificationCode, target: "86-13900000001", purpose: "admin_login")
    end

    # core 的发码接口是公开的:不知道密码也能让管理员的手机响
    test "密码不对不会发出验证码", %{conn: conn} do
      assert conn
             |> post(~p"/api/admin/session/challenge", %{
               phone: "13900000001",
               phone_region: "86",
               password: "猜的"
             })
             |> json_response(401)

      refute Rice.Repo.get_by(VerificationCode, target: "86-13900000001")
    end

    test "密码 + 验证码换令牌", %{conn: conn, admin: admin} do
      code = seed_code("86-13900000001", "admin_login")

      assert %{"data" => %{"token" => token, "admin" => data}} =
               conn
               |> post(~p"/api/admin/session", %{
                 phone: "13900000001",
                 phone_region: "86",
                 password: "admin-password",
                 code: code
               })
               |> json_response(201)

      assert data["id"] == admin.id
      assert data["role"] == "admin"
      # 摘要和盐一个字节都不该出现在响应里
      refute Map.has_key?(data, "password_hash")
      refute Map.has_key?(data, "password_salt")

      assert %{"data" => me} =
               build_conn() |> authed(token) |> get(~p"/api/admin/me") |> json_response(200)

      assert me["id"] == admin.id
    end

    # 只有验证码不够 —— 手机被别人拿到也不该等于拿到后台
    test "只有验证码、密码错的,换不到令牌", %{conn: conn} do
      code = seed_code("86-13900000001", "admin_login")

      assert conn
             |> post(~p"/api/admin/session", %{
               phone: "13900000001",
               phone_region: "86",
               password: "猜的",
               code: code
             })
             |> json_response(401)
    end

    test "换个用途的验证码不认", %{conn: conn} do
      code = seed_code("86-13900000001", "admin_reset_password")

      assert conn
             |> post(~p"/api/admin/session", %{
               phone: "13900000001",
               phone_region: "86",
               password: "admin-password",
               code: code
             })
             |> json_response(401)
    end

    test "被停用的管理员登不进来", %{conn: conn, admin: admin} do
      Rice.Repo.update!(Ecto.Changeset.change(admin, disabled_at: DateTime.utc_now()))
      code = seed_code("86-13900000001", "admin_login")

      assert conn
             |> post(~p"/api/admin/session", %{
               phone: "13900000001",
               phone_region: "86",
               password: "admin-password",
               code: code
             })
             |> json_response(401)
    end

    # 账号不存在和密码错必须长得一样,否则就是个"谁是管理员"的探测器
    test "账号不存在与密码错的响应完全相同", %{conn: _conn} do
      a =
        build_conn()
        |> post(~p"/api/admin/session/challenge", %{
          phone: "13900000001",
          phone_region: "86",
          password: "错的"
        })

      b =
        build_conn()
        |> post(~p"/api/admin/session/challenge", %{
          phone: "13900009999",
          phone_region: "86",
          password: "错的"
        })

      assert a.status == b.status
      assert a.resp_body == b.resp_body
    end
  end

  describe "会话" do
    test "登出后令牌立即失效", %{conn: conn} do
      {_admin, token} = admin_with_token()

      assert conn |> authed(token) |> delete(~p"/api/admin/session") |> response(204)
      assert build_conn() |> authed(token) |> get(~p"/api/admin/me") |> json_response(401)
    end

    test "未认证 401", %{conn: conn} do
      assert conn |> get(~p"/api/admin/me") |> json_response(401)
    end

    # 两套令牌互相换不过去
    test "C 端令牌不能当管理端令牌用", %{conn: conn} do
      {_user, user_token} = user_with_token()

      assert conn |> authed(user_token) |> get(~p"/api/admin/me") |> json_response(401)
    end

    test "管理端令牌不能当 C 端令牌用", %{conn: conn} do
      {_admin, admin_token} = admin_with_token()

      assert conn |> authed(admin_token) |> get(~p"/api/users/me") |> json_response(401)
    end
  end
end
