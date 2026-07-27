defmodule RiceWeb.Api.NodeControllerTest do
  use RiceWeb.ConnCase, async: true

  describe "GET /api/nodes" do
    test "空库返回空数组", %{conn: conn} do
      assert %{"data" => []} = conn |> get(~p"/api/nodes") |> json_response(200)
    end

    test "按 position 升序,带节点主", %{conn: conn} do
      owner = user_fixture(%{nickname: "主理人"}) |> give_grain(777)
      node_fixture(%{name: "乙", position: 2})
      node_fixture(%{name: "甲", position: 1, user_id: owner.id})

      assert %{"data" => data} = conn |> get(~p"/api/nodes") |> json_response(200)
      assert Enum.map(data, & &1["name"]) == ["甲", "乙"]

      [first, second] = data
      assert first["owner"]["nickname"] == "主理人"
      # core 的 NodeListVo 把 did 和稻米摊平在顶层,这里是嵌套对象
      assert first["owner"]["did"] == owner.did
      assert first["owner"]["grain_balance"] == 777
      assert is_nil(second["owner"])
    end

    test "节点主的联系方式不外露", %{conn: conn} do
      owner = user_fixture(%{email: "secret@example.com", phone: "13800000000"})
      node_fixture(%{user_id: owner.id})

      body = conn |> get(~p"/api/nodes") |> response(200)

      refute body =~ "secret@example.com"
      refute body =~ "13800000000"
    end
  end

  describe "GET /api/nodes/members" do
    test "只列节点用户", %{conn: conn} do
      member = user_fixture(%{nickname: "节点用户"})
      Rice.Repo.update!(Ecto.Changeset.change(member, node_member: true))
      user_fixture(%{nickname: "普通用户"})

      assert %{"data" => [one]} = conn |> get(~p"/api/nodes/members") |> json_response(200)
      assert one["nickname"] == "节点用户"
    end

    test "被禁用或软删的节点用户不出现", %{conn: conn} do
      disabled = user_fixture()

      Rice.Repo.update!(
        Ecto.Changeset.change(disabled, node_member: true, disabled_at: DateTime.utc_now())
      )

      deleted = user_fixture()

      Rice.Repo.update!(
        Ecto.Changeset.change(deleted, node_member: true, deleted_at: DateTime.utc_now())
      )

      assert %{"data" => []} = conn |> get(~p"/api/nodes/members") |> json_response(200)
    end
  end
end
