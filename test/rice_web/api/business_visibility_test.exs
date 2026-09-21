defmodule RiceWeb.Api.BusinessVisibilityTest do
  use RiceWeb.ConnCase, async: true

  test "承接者可以看任务进展，但不能借进展查看其他候选身份" do
    {host, host_token} = user_with_token()
    {worker, worker_token} = user_with_token()
    other = user_fixture()
    node_fixture(%{user_id: host.id})

    {:ok, task} =
      Rice.Tasks.create_task(host, %{organizer_contact: "社区服务台", title: "任务", description: "交付内容"})

    {:ok, selected} = Rice.Tasks.apply(worker, task, %{contact: "测试联系方式", reason: "本人申请"})
    {:ok, _} = Rice.Tasks.apply(other, task, %{contact: "测试联系方式", reason: "其他人的申请"})
    {:ok, _} = Rice.Tasks.appoint(host, task, selected.id, %{appointment_reason: "内部选人说明"})

    own =
      build_conn() |> authed(worker_token) |> get(~p"/api/tasks/#{task.id}") |> json_response(200)

    assert Enum.any?(own["data"]["events"], &(&1["to_status"] == "in_progress"))
    refute inspect(own) =~ other.did
    public = build_conn() |> get(~p"/api/tasks/#{task.id}") |> json_response(200)
    assert public["data"]["appointment_reason"] == nil
    refute inspect(public) =~ other.did

    manager =
      build_conn() |> authed(host_token) |> get(~p"/api/tasks/#{task.id}") |> json_response(200)

    assert Enum.count(manager["data"]["events"], &(&1["detail"] == "收到任务申请")) == 2
  end

  test "钱包与业务通知只返回当前登录账号的内容" do
    {first, first_token} = user_with_token()
    {second, second_token} = user_with_token()
    {:ok, _} = Rice.Grains.grant(first, 100)

    {:ok, _} =
      Rice.Inbox.notify(
        Rice.Repo,
        first.id,
        second.id,
        "community_approved",
        "加入申请已通过",
        "node",
        Rice.Tsid.generate()
      )

    assert build_conn() |> get(~p"/api/wallet") |> json_response(401)
    assert build_conn() |> get(~p"/api/notifications") |> json_response(401)
    own = build_conn() |> authed(first_token) |> get(~p"/api/wallet") |> json_response(200)
    assert own["data"]["earned"] == 100
    other = build_conn() |> authed(second_token) |> get(~p"/api/wallet") |> json_response(200)
    assert other["data"]["entries"] == []

    assert %{"notifications" => []} =
             build_conn()
             |> authed(second_token)
             |> get(~p"/api/notifications")
             |> json_response(200)

    received =
      build_conn() |> authed(first_token) |> get(~p"/api/notifications") |> json_response(200)

    assert length(received["notifications"]) == 1
    assert hd(received["notifications"])["subjectType"] == "node"
  end
end
