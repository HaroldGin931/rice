defmodule RiceWeb.Api.UserControllerTest do
  use RiceWeb.ConnCase, async: true

  describe "GET /api/users/me" do
    test "返回完整档案(含私有字段)", %{conn: conn} do
      {user, token} =
        user_with_token(%{email: "a@example.com", phone: "13800000000", nickname: "小明"})

      assert %{"data" => data} =
               conn |> authed(token) |> get(~p"/api/users/me") |> json_response(200)

      assert data["id"] == user.id
      assert data["did"] == user.did
      assert data["handle"] == user.handle
      assert data["nickname"] == "小明"
      assert data["email"] == "a@example.com"
      assert data["phone"] == "13800000000"
      assert data["grain_balance"] == 0
      assert data["grain_frozen_balance"] == 0
      assert data["node_member"] == false
    end

    test "Semi 用户带出钱包地址", %{conn: conn} do
      {user, token} = user_with_token()

      {:ok, _} =
        Rice.Accounts.create_link(%{
          semi_sub: "semi-sub-1",
          did: user.did,
          handle: user.handle,
          account_password_ciphertext: Rice.Vault.encrypt("pw"),
          wallet_address: "0x1234567890abcdef1234567890abcdef12345678"
        })

      assert %{"data" => data} =
               conn |> authed(token) |> get(~p"/api/users/me") |> json_response(200)

      assert data["wallet_address"] == "0x1234567890abcdef1234567890abcdef12345678"
    end

    test "非 Semi 用户的钱包地址是 null", %{conn: conn} do
      {_user, token} = user_with_token()

      assert %{"data" => data} =
               conn |> authed(token) |> get(~p"/api/users/me") |> json_response(200)

      assert Map.has_key?(data, "wallet_address")
      assert data["wallet_address"] == nil
    end

    # 地址在链上是公开的,但和社交身份绑一起会把可关联性拉高 ——
    # 要不要外露是产品决定,默认不外露。
    test "钱包地址不出现在别人看得到的地方", %{conn: conn} do
      # node_member 不在 registration_changeset 里(注册时不该自称节点成员)
      user =
        user_fixture() |> Ecto.Changeset.change(node_member: true) |> Rice.Repo.update!()

      {:ok, _} =
        Rice.Accounts.create_link(%{
          semi_sub: "semi-sub-2",
          did: user.did,
          handle: user.handle,
          account_password_ciphertext: Rice.Vault.encrypt("pw"),
          wallet_address: "0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
        })

      assert %{"data" => [member]} =
               conn |> get(~p"/api/nodes/members") |> json_response(200)

      assert member["did"] == user.did
      refute Map.has_key?(member, "wallet_address")
    end

    test "未认证 401", %{conn: conn} do
      assert conn |> get(~p"/api/users/me") |> json_response(401)
    end

    test "各种坏令牌都是 401", %{conn: conn} do
      for header <- ["", "Bearer", "Bearer ", "Basic abc", "Bearer nope", "bearer lower"] do
        assert conn
               |> put_req_header("authorization", header)
               |> get(~p"/api/users/me")
               |> json_response(401)
      end
    end
  end

  describe "PATCH /api/users/me" do
    test "改昵称和简介", %{conn: conn} do
      {_user, token} = user_with_token()

      assert %{"data" => data} =
               conn
               |> authed(token)
               |> patch(~p"/api/users/me", %{nickname: "新昵称", bio: "简介"})
               |> json_response(200)

      assert data["nickname"] == "新昵称"
      assert data["bio"] == "简介"
    end

    test "设置头像", %{conn: conn} do
      {_user, token} = user_with_token()
      avatar = attachment_fixture()

      assert %{"data" => %{"avatar" => %{"id" => id}}} =
               conn
               |> authed(token)
               |> patch(~p"/api/users/me", %{avatar_id: avatar.id})
               |> json_response(200)

      assert id == avatar.id
    end

    # 这几个字段被改掉就是越权:did/handle 是身份,余额是钱,node_member 是权限
    test "改不动 did / handle / 余额 / 节点身份 / 禁用状态", %{conn: conn} do
      {user, token} = user_with_token()

      conn
      |> authed(token)
      |> patch(~p"/api/users/me", %{
        did: "did:plc:hacker",
        handle: "hacker.test",
        grain_balance: 999_999,
        node_member: true,
        disabled_at: nil,
        legacy_id: "x"
      })
      |> json_response(200)

      reloaded = Rice.Repo.get!(Rice.Accounts.User, user.id)
      assert reloaded.did == user.did
      assert reloaded.handle == user.handle
      assert reloaded.grain_balance == 0
      assert reloaded.node_member == false
      assert is_nil(reloaded.legacy_id)
    end

    test "不能直接改邮箱手机 —— 那要走验证码", %{conn: conn} do
      {user, token} = user_with_token()

      conn
      |> authed(token)
      |> patch(~p"/api/users/me", %{email: "new@example.com", phone: "13900000000"})
      |> json_response(200)

      reloaded = Rice.Repo.get!(Rice.Accounts.User, user.id)
      assert is_nil(reloaded.email)
      assert is_nil(reloaded.phone)
    end

    test "超长字段返回 422", %{conn: conn} do
      {_user, token} = user_with_token()

      assert %{"errors" => errors} =
               conn
               |> authed(token)
               |> patch(~p"/api/users/me", %{nickname: String.duplicate("字", 65)})
               |> json_response(422)

      assert errors["nickname"]
    end

    test "指向不存在的头像返回 422", %{conn: conn} do
      {_user, token} = user_with_token()

      assert conn
             |> authed(token)
             |> patch(~p"/api/users/me", %{avatar_id: Rice.Tsid.generate()})
             |> json_response(422)
    end

    test "未认证 401", %{conn: conn} do
      assert conn |> patch(~p"/api/users/me", %{nickname: "x"}) |> json_response(401)
    end
  end

  describe "DELETE /api/users/me" do
    alias Rice.Accounts.VerificationCode

    defp seed_code(channel, target, purpose) do
      code = VerificationCode.generate_code()
      Rice.Repo.insert!(VerificationCode.build(channel, target, purpose, code))
      code
    end

    test "凭验证码软删并撤销令牌", %{conn: conn} do
      {user, token} = user_with_token(%{email: "bye@example.com"})
      code = seed_code("email", "bye@example.com", "delete_account")

      assert conn
             |> authed(token)
             |> delete(~p"/api/users/me", %{channel: "email", code: code})
             |> response(204)

      reloaded = Rice.Repo.get!(Rice.Accounts.User, user.id)
      refute is_nil(reloaded.deleted_at)
      assert build_conn() |> authed(token) |> get(~p"/api/users/me") |> json_response(401)
    end

    # 注销不可逆 —— 只有令牌不够,必须当场再验一次联系方式
    test "没有验证码删不掉", %{conn: conn} do
      {user, token} = user_with_token(%{email: "bye@example.com"})

      assert conn |> authed(token) |> delete(~p"/api/users/me") |> json_response(422)
      assert is_nil(Rice.Repo.get!(Rice.Accounts.User, user.id).deleted_at)
    end

    test "验证码不对删不掉", %{conn: conn} do
      {user, token} = user_with_token(%{email: "bye@example.com"})
      seed_code("email", "bye@example.com", "delete_account")

      assert %{"errors" => %{"code" => _}} =
               conn
               |> authed(token)
               |> delete(~p"/api/users/me", %{channel: "email", code: "000000"})
               |> json_response(422)

      assert is_nil(Rice.Repo.get!(Rice.Accounts.User, user.id).deleted_at)
    end

    # 拿别人联系方式上的验证码来删自己的号也不行
    test "验证码必须发到自己绑定的联系方式", %{conn: conn} do
      {user, token} = user_with_token(%{email: "mine@example.com"})
      code = seed_code("email", "someone.else@example.com", "delete_account")

      assert conn
             |> authed(token)
             |> delete(~p"/api/users/me", %{channel: "email", code: code})
             |> json_response(422)

      assert is_nil(Rice.Repo.get!(Rice.Accounts.User, user.id).deleted_at)
    end

    test "换个用途的验证码也不行", %{conn: conn} do
      {user, token} = user_with_token(%{email: "bye@example.com"})
      code = seed_code("email", "bye@example.com", "reset_password")

      assert conn
             |> authed(token)
             |> delete(~p"/api/users/me", %{channel: "email", code: code})
             |> json_response(422)

      assert is_nil(Rice.Repo.get!(Rice.Accounts.User, user.id).deleted_at)
    end

    test "没绑这个渠道就报 channel 错", %{conn: conn} do
      {_user, token} = user_with_token(%{email: "bye@example.com"})

      assert %{"errors" => %{"channel" => _}} =
               conn
               |> authed(token)
               |> delete(~p"/api/users/me", %{channel: "sms", code: "123456"})
               |> json_response(422)
    end

    test "未认证 401", %{conn: conn} do
      assert conn |> delete(~p"/api/users/me") |> json_response(401)
    end
  end
end
