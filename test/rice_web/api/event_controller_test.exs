defmodule RiceWeb.Api.EventControllerTest do
  use RiceWeb.ConnCase, async: true
  alias Rice.{Events, Repo}

  test "API 提供真实候选管理、私人申请和本人回访", %{conn: conn} do
    {host, host_token} = user_with_token()
    {first, first_token} = user_with_token()
    {second, second_token} = user_with_token()
    node = node_fixture(%{user_id: host.id})
    for user <- [first, second], do: Rice.Grains.grant(user, 50)
    now = DateTime.utc_now()

    attrs = %{
      node_id: node.id,
      title: "公共客厅修理",
      description: "一起修好木凳",
      location: "公共客厅",
      fee_amount: 20,
      capacity: 1,
      client_request_id: "publish-#{System.unique_integer([:positive])}",
      application_deadline: DateTime.add(now, 1800),
      starts_at: DateTime.add(now, 3600),
      ends_at: DateTime.add(now, 7200)
    }

    assert build_conn() |> post(~p"/api/events", attrs) |> json_response(401)

    assert build_conn()
           |> authed(first_token)
           |> post(~p"/api/events", attrs)
           |> json_response(403)

    created = conn |> authed(host_token) |> post(~p"/api/events", attrs) |> json_response(201)
    id = created["data"]["id"]
    assert created["data"]["node"]["id"] == node.id
    assert created["data"]["creator"]["id"] == host.id

    first_result =
      build_conn()
      |> authed(first_token)
      |> post(~p"/api/events/#{id}/applications", %{reason: "第一位的私人申请"})
      |> json_response(200)

    a_id = first_result["data"]["my_application"]["id"]
    assert first_result["data"]["my_application"]["status"] == "pending"

    second_result =
      build_conn()
      |> authed(second_token)
      |> post(~p"/api/events/#{id}/applications", %{reason: "第二位的私人申请"})
      |> json_response(200)

    b_id = second_result["data"]["my_application"]["id"]
    assert second_result["data"]["application_count"] == 2

    public = build_conn() |> get(~p"/api/events/#{id}") |> json_response(200)
    assert public["data"]["applications"] == []
    refute inspect(public) =~ "私人申请"
    refute Enum.any?(public["data"]["history"], &(&1["action"] == "applied"))
    mine = build_conn() |> authed(first_token) |> get(~p"/api/events/#{id}") |> json_response(200)
    assert length(mine["data"]["applications"]) == 1
    assert Enum.count(mine["data"]["history"], &(&1["action"] == "applied")) == 1
    refute Enum.any?(mine["data"]["history"], &(&1["actor"] && &1["actor"]["id"] == second.id))

    assert build_conn()
           |> authed(second_token)
           |> post(~p"/api/events/#{id}/applications/#{a_id}/approve")
           |> json_response(403)

    approved =
      build_conn()
      |> authed(host_token)
      |> post(~p"/api/events/#{id}/applications/#{a_id}/approve")
      |> json_response(200)

    assert approved["data"]["approved_count"] == 1

    assert %{"data" => [%{"id" => ^id}]} =
             build_conn()
             |> get("/api/events", %{participant_did: first.did})
             |> json_response(200)

    assert %{"data" => []} =
             build_conn()
             |> get("/api/events", %{participant_did: second.did})
             |> json_response(200)

    assert %{"data" => [%{"id" => ^id}]} =
             build_conn() |> get("/api/events", %{creator_did: host.did}) |> json_response(200)

    assert build_conn()
           |> authed(host_token)
           |> post(~p"/api/events/#{id}/applications/#{b_id}/approve")
           |> json_response(409)

    revisited =
      build_conn()
      |> authed(first_token)
      |> get(~p"/api/events?mine=applied")
      |> json_response(200)

    assert hd(revisited["data"])["my_application"]["status"] == "approved"
    assert {:ok, event} = Events.fetch_event(id, host)
    assert {:ok, _} = Events.cancel(host, event)
    assert Repo.get!(Rice.Accounts.User, first.id).grain_balance == 50
    assert Repo.get!(Rice.Accounts.User, second.id).grain_balance == 50
  end

  test "非法输入返回错误，草稿仅本人可见" do
    {host, token} = user_with_token()
    node = node_fixture(%{user_id: host.id})
    now = DateTime.utc_now()

    attrs = %{
      node_id: node.id,
      title: "草稿",
      description: "描述",
      location: "地点",
      status: "draft",
      capacity: 1,
      application_deadline: DateTime.add(now, 60),
      starts_at: DateTime.add(now, 120),
      ends_at: DateTime.add(now, 180)
    }

    assert build_conn()
           |> authed(token)
           |> post(~p"/api/events", Map.put(attrs, :title, nil))
           |> json_response(422)

    created = build_conn() |> authed(token) |> post(~p"/api/events", attrs) |> json_response(201)
    id = created["data"]["id"]
    assert build_conn() |> get(~p"/api/events/#{id}") |> json_response(404)
    assert %{"data" => []} = build_conn() |> get(~p"/api/events") |> json_response(200)

    assert %{"data" => [%{"id" => ^id}]} =
             build_conn()
             |> authed(token)
             |> get(~p"/api/events?mine=created&status=draft")
             |> json_response(200)

    assert build_conn() |> get(~p"/api/events/not-an-id") |> json_response(404)
  end
end
