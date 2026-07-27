defmodule RiceWeb.Api.PasswordControllerTest do
  use RiceWeb.ConnCase, async: true

  import Mox
  setup :verify_on_exit!

  alias Rice.Accounts.VerificationCode

  defp seed_code(channel, target, purpose \\ "reset_password") do
    code = VerificationCode.generate_code()
    Rice.Repo.insert!(VerificationCode.build(channel, target, purpose, code))
    code
  end

  describe "POST /api/passwords/reset" do
    setup do
      %{user: user_fixture(%{phone: "13800000000", phone_region: "86", email: "a@example.com"})}
    end

    test "凭手机验证码重置", %{conn: conn, user: user} do
      code = seed_code("sms", "86-13800000000")

      expect(Rice.PDSMock, :update_account_password, fn did, "newpassword" ->
        assert did == user.did
        :ok
      end)

      assert conn
             |> post(~p"/api/passwords/reset", %{
               channel: "sms",
               phone: "13800000000",
               code: code,
               password: "newpassword"
             })
             |> response(204)
    end

    test "凭邮箱验证码重置", %{conn: conn, user: user} do
      code = seed_code("email", "a@example.com")
      expect(Rice.PDSMock, :update_account_password, fn _, _ -> :ok end)

      assert conn
             |> post(~p"/api/passwords/reset", %{
               channel: "email",
               email: "a@example.com",
               code: code,
               password: "newpassword"
             })
             |> response(204)

      _ = user
    end

    # 改了密码就该把别处的登录踢掉。JWT 做不到这件事。
    test "重置后原有令牌全部失效", %{conn: conn, user: user} do
      {:ok, token} = Rice.Accounts.issue_token(user)
      code = seed_code("sms", "86-13800000000")
      expect(Rice.PDSMock, :update_account_password, fn _, _ -> :ok end)

      assert Rice.Accounts.user_by_token(token)

      conn
      |> post(~p"/api/passwords/reset", %{
        channel: "sms",
        phone: "13800000000",
        code: code,
        password: "newpassword"
      })
      |> response(204)

      refute Rice.Accounts.user_by_token(token)
    end

    test "验证码错误 422", %{conn: conn} do
      seed_code("sms", "86-13800000000")

      assert conn
             |> post(~p"/api/passwords/reset", %{
               channel: "sms",
               phone: "13800000000",
               code: "000000",
               password: "newpassword"
             })
             |> json_response(422)
    end

    # 手机号没注册过与验证码错误必须返回同样的东西,否则这就是一个
    # "这个号码注册过没有" 的探测接口
    test "未注册的号码与验证码错误的响应完全一致", %{conn: conn} do
      seed_code("sms", "86-13800000000")
      code_for_unknown = seed_code("sms", "86-13911111111")

      wrong_code =
        conn
        |> post(~p"/api/passwords/reset", %{
          channel: "sms",
          phone: "13800000000",
          code: "000000",
          password: "newpassword"
        })
        |> json_response(422)

      unknown_user =
        build_conn()
        |> post(~p"/api/passwords/reset", %{
          channel: "sms",
          phone: "13911111111",
          code: code_for_unknown,
          password: "newpassword"
        })
        |> json_response(422)

      assert wrong_code == unknown_user
    end

    test "密码太短 422,且不消耗验证码之外的东西", %{conn: conn} do
      code = seed_code("sms", "86-13800000000")

      assert conn
             |> post(~p"/api/passwords/reset", %{
               channel: "sms",
               phone: "13800000000",
               code: code,
               password: "short"
             })
             |> json_response(422)
    end

    test "注册用的验证码不能拿来重置密码", %{conn: conn} do
      code = seed_code("sms", "86-13800000000", "register")

      assert conn
             |> post(~p"/api/passwords/reset", %{
               channel: "sms",
               phone: "13800000000",
               code: code,
               password: "newpassword"
             })
             |> json_response(422)
    end
  end

  describe "PUT /api/users/me/phone 和 /email" do
    test "改绑手机", %{conn: conn} do
      {_user, token} = user_with_token()
      code = seed_code("sms", "86-13900000000", "modify_phone")

      assert %{"data" => %{"phone" => "13900000000"}} =
               conn
               |> authed(token)
               |> put(~p"/api/users/me/phone", %{phone: "13900000000", code: code})
               |> json_response(200)
    end

    test "改绑邮箱", %{conn: conn} do
      {_user, token} = user_with_token()
      code = seed_code("email", "new@example.com", "modify_email")

      assert %{"data" => %{"email" => "new@example.com"}} =
               conn
               |> authed(token)
               |> put(~p"/api/users/me/email", %{email: "new@example.com", code: code})
               |> json_response(200)
    end

    test "验证码不对时不改", %{conn: conn} do
      {user, token} = user_with_token(%{phone: "13800000000"})
      seed_code("sms", "86-13900000000", "modify_phone")

      assert conn
             |> authed(token)
             |> put(~p"/api/users/me/phone", %{phone: "13900000000", code: "000000"})
             |> json_response(422)

      assert Rice.Repo.get!(Rice.Accounts.User, user.id).phone == "13800000000"
    end

    test "改成别人已占用的号码 422", %{conn: conn} do
      user_fixture(%{phone: "13900000000", phone_region: "86"})
      {_user, token} = user_with_token()
      code = seed_code("sms", "86-13900000000", "modify_phone")

      assert %{"errors" => errors} =
               conn
               |> authed(token)
               |> put(~p"/api/users/me/phone", %{phone: "13900000000", code: code})
               |> json_response(422)

      assert errors["phone"] == ["该手机号已被使用"]
    end

    test "未认证 401", %{conn: conn} do
      assert conn |> put(~p"/api/users/me/phone", %{phone: "1", code: "1"}) |> json_response(401)
      assert conn |> put(~p"/api/users/me/email", %{email: "a", code: "1"}) |> json_response(401)
    end
  end
end
