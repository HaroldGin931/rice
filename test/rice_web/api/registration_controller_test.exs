defmodule RiceWeb.Api.RegistrationControllerTest do
  use RiceWeb.ConnCase, async: true

  import Mox
  setup :verify_on_exit!

  alias Rice.Accounts.VerificationCode

  defp seed_code(channel, target) do
    code = VerificationCode.generate_code()
    Rice.Repo.insert!(VerificationCode.build(channel, target, "register", code))
    code
  end

  defp ticket_for(conn, phone) do
    code = seed_code("sms", Rice.Accounts.phone_target("86", phone))

    conn
    |> post(~p"/api/registrations/verification", %{channel: "sms", phone: phone, code: code})
    |> json_response(200)
    |> get_in(["data", "ticket"])
  end

  describe "POST /api/verification_codes" do
    test "发短信验证码返回 204", %{conn: conn} do
      expect(Rice.NotificationsMock, :send_sms, fn "86", "13800000000", _ -> :ok end)

      assert conn
             |> post(~p"/api/verification_codes", %{
               channel: "sms",
               phone: "13800000000",
               purpose: "register"
             })
             |> response(204)
    end

    test "发邮件验证码返回 204", %{conn: conn} do
      expect(Rice.NotificationsMock, :send_email, fn "a@example.com", _, _ -> :ok end)

      assert conn
             |> post(~p"/api/verification_codes", %{
               channel: "email",
               email: "a@example.com",
               purpose: "register"
             })
             |> response(204)
    end

    # core 完全没有这层,同一个号码可以被无限轰炸
    test "60 秒内重复请求返回 429", %{conn: conn} do
      expect(Rice.NotificationsMock, :send_sms, fn _, _, _ -> :ok end)
      params = %{channel: "sms", phone: "13800000000", purpose: "register"}

      assert conn |> post(~p"/api/verification_codes", params) |> response(204)
      assert build_conn() |> post(~p"/api/verification_codes", params) |> json_response(429)
    end

    test "非法通道或用途返回 422", %{conn: conn} do
      for params <- [
            %{channel: "carrier", phone: "1", purpose: "register"},
            %{channel: "sms", phone: "1", purpose: "hack"},
            %{channel: "sms", purpose: "register"},
            %{}
          ] do
        assert conn |> post(~p"/api/verification_codes", params) |> json_response(422)
      end
    end

    test "响应体里绝不包含验证码", %{conn: conn} do
      sent = :atomics.new(1, signed: false)

      expect(Rice.NotificationsMock, :send_sms, fn _, _, text ->
        [code] = Regex.run(~r/\d{6}/, text)
        :atomics.put(sent, 1, String.to_integer(code))
        :ok
      end)

      body =
        conn
        |> post(~p"/api/verification_codes", %{
          channel: "sms",
          phone: "13800000000",
          purpose: "register"
        })
        |> response(204)

      code = :atomics.get(sent, 1) |> Integer.to_string() |> String.pad_leading(6, "0")
      assert body == ""
      refute body =~ code
    end
  end

  describe "POST /api/registrations/verification" do
    test "验证码正确时换到一张票", %{conn: conn} do
      code = seed_code("sms", Rice.Accounts.phone_target("86", "13800000000"))

      assert %{"data" => %{"ticket" => ticket, "expires_in" => 1800}} =
               conn
               |> post(~p"/api/registrations/verification", %{
                 channel: "sms",
                 phone: "13800000000",
                 code: code
               })
               |> json_response(200)

      assert is_binary(ticket)
    end

    test "验证码错误返回 422", %{conn: conn} do
      seed_code("sms", Rice.Accounts.phone_target("86", "13800000000"))

      assert conn
             |> post(~p"/api/registrations/verification", %{
               channel: "sms",
               phone: "13800000000",
               code: "000000"
             })
             |> json_response(422)
    end

    test "猜太多次后返回 429", %{conn: conn} do
      seed_code("sms", Rice.Accounts.phone_target("86", "13800000000"))
      params = %{channel: "sms", phone: "13800000000", code: "000000"}

      for _ <- 1..VerificationCode.max_attempts() do
        build_conn() |> post(~p"/api/registrations/verification", params) |> json_response(422)
      end

      assert conn |> post(~p"/api/registrations/verification", params) |> json_response(429)
    end
  end

  describe "POST /api/registrations" do
    test "凭票完成注册", %{conn: conn} do
      ticket = ticket_for(conn, "13800000000")

      expect(Rice.PDSMock, :email_domain, fn -> "web5.xjdao.test" end)

      expect(Rice.PDSMock, :create_account, fn %{handle: "alice.web5.xjdao.test"} ->
        {:ok,
         %{
           "did" => "did:plc:alice",
           "handle" => "alice.web5.xjdao.test",
           "accessJwt" => "acc",
           "refreshJwt" => "ref"
         }}
      end)

      assert %{"data" => data} =
               build_conn()
               |> post(~p"/api/registrations", %{
                 ticket: ticket,
                 handle: "alice.web5.xjdao.test",
                 password: "hunter2hunter2"
               })
               |> json_response(201)

      assert data["user"]["did"] == "did:plc:alice"
      # 手机号来自票据,不是客户端传的
      assert data["user"]["phone"] == "13800000000"
      assert is_binary(data["token"])
    end

    # 票据里带着已验证的联系方式。若能被客户端覆盖,验证码就形同虚设 ——
    # 拿自己的手机验一次,就能给任意号码注册。
    test "票据里的手机号不可被请求参数覆盖", %{conn: conn} do
      ticket = ticket_for(conn, "13800000000")

      expect(Rice.PDSMock, :email_domain, fn -> "web5.xjdao.test" end)

      expect(Rice.PDSMock, :create_account, fn _ ->
        {:ok, %{"did" => "did:plc:a", "handle" => "a.test", "accessJwt" => "acc"}}
      end)

      assert %{"data" => data} =
               build_conn()
               |> post(~p"/api/registrations", %{
                 ticket: ticket,
                 handle: "a.test",
                 password: "hunter2hunter2",
                 phone: "13900000000",
                 email: "attacker@example.com"
               })
               |> json_response(201)

      assert data["user"]["phone"] == "13800000000"
      assert is_nil(data["user"]["email"])
    end

    test "没有票 / 票伪造 / 票过期都是 422", %{conn: conn} do
      for ticket <- [nil, "", "forged", Phoenix.Token.sign(RiceWeb.Endpoint, "别的 salt", %{})] do
        assert conn
               |> post(~p"/api/registrations", %{
                 ticket: ticket,
                 handle: "a.test",
                 password: "hunter2hunter2"
               })
               |> json_response(422)
      end
    end

    test "密码短于 8 位被拒", %{conn: conn} do
      ticket = ticket_for(conn, "13800000000")

      assert %{"errors" => %{"detail" => detail}} =
               build_conn()
               |> post(~p"/api/registrations", %{
                 ticket: ticket,
                 handle: "a.test",
                 password: "short"
               })
               |> json_response(422)

      assert detail =~ "8"
    end

    test "缺 handle 被拒", %{conn: conn} do
      ticket = ticket_for(conn, "13800000000")

      assert build_conn()
             |> post(~p"/api/registrations", %{ticket: ticket, password: "hunter2hunter2"})
             |> json_response(422)
    end

    test "PDS 说 handle 被占用时返回 422 而不是 500", %{conn: conn} do
      ticket = ticket_for(conn, "13800000000")

      expect(Rice.PDSMock, :email_domain, fn -> "web5.xjdao.test" end)

      expect(Rice.PDSMock, :create_account, fn _ ->
        {:error, {:pds, "createAccount", 400, "HandleNotAvailable"}}
      end)

      assert %{"errors" => %{"handle" => ["HandleNotAvailable"]}} =
               build_conn()
               |> post(~p"/api/registrations", %{
                 ticket: ticket,
                 handle: "taken.test",
                 password: "hunter2hunter2"
               })
               |> json_response(422)
    end

    test "手机号已被占用时返回 422,且不去建 PDS 账号", %{conn: conn} do
      user_fixture(%{phone: "13800000000", phone_region: "86"})
      ticket = ticket_for(conn, "13800000000")

      assert build_conn()
             |> post(~p"/api/registrations", %{
               ticket: ticket,
               handle: "a.test",
               password: "hunter2hunter2"
             })
             |> json_response(422)
    end
  end
end
