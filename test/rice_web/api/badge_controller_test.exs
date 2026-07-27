defmodule RiceWeb.Api.BadgeControllerTest do
  use RiceWeb.ConnCase, async: true

  import Rice.DataCase, only: [errors_on: 1]

  describe "GET /api/users/me/badges" do
    test "列出自己获得的勋章", %{conn: conn} do
      {user, token} = user_with_token()
      image = attachment_fixture(%{filename: "medal.png"})
      badge = badge_fixture(%{name: "早期贡献者", image_id: image.id})
      {:ok, _} = Rice.Community.award_badge(badge, user)

      assert %{"data" => [one]} =
               conn |> authed(token) |> get(~p"/api/users/me/badges") |> json_response(200)

      assert one["name"] == "早期贡献者"
      assert one["image"]["filename"] == "medal.png"
      assert one["awarded_at"]
    end

    test "看不到别人的勋章", %{conn: conn} do
      {_me, token} = user_with_token()
      other = user_fixture()
      badge = badge_fixture()
      {:ok, _} = Rice.Community.award_badge(badge, other)

      assert %{"data" => []} =
               conn |> authed(token) |> get(~p"/api/users/me/badges") |> json_response(200)
    end

    # core 的 t_user_medal 上没有这个约束
    test "同一枚勋章不能重复发给同一个人" do
      user = user_fixture()
      badge = badge_fixture()

      assert {:ok, _} = Rice.Community.award_badge(badge, user)
      assert {:error, changeset} = Rice.Community.award_badge(badge, user)
      assert "该用户已获得这枚勋章" in errors_on(changeset).badge_id
    end

    test "持有人数是现算的,不是缓存字段" do
      badge = badge_fixture()
      assert Rice.Community.badge_holder_count(badge) == 0

      for _ <- 1..3, do: {:ok, _} = Rice.Community.award_badge(badge, user_fixture())
      assert Rice.Community.badge_holder_count(badge) == 3
    end

    test "未认证 401", %{conn: conn} do
      assert conn |> get(~p"/api/users/me/badges") |> json_response(401)
    end
  end

  describe "GET /api/badges" do
    test "列出全部勋章,自己没获得的 awarded_at 是 null", %{conn: conn} do
      {user, token} = user_with_token()
      got = badge_fixture(%{name: "已获得"})
      _missing = badge_fixture(%{name: "未获得"})
      {:ok, _} = Rice.Community.award_badge(got, user)

      assert %{"data" => data} =
               conn |> authed(token) |> get(~p"/api/badges") |> json_response(200)

      by_name = Map.new(data, &{&1["name"], &1["awarded_at"]})
      assert by_name["已获得"]
      assert Map.has_key?(by_name, "未获得")
      assert by_name["未获得"] == nil
    end

    test "未登录也能看,全部 awarded_at 为 null", %{conn: conn} do
      user = user_fixture()
      badge = badge_fixture(%{name: "谁都能看见"})
      {:ok, _} = Rice.Community.award_badge(badge, user)

      assert %{"data" => [one]} = conn |> get(~p"/api/badges") |> json_response(200)
      assert one["name"] == "谁都能看见"
      assert one["awarded_at"] == nil
    end
  end
end
