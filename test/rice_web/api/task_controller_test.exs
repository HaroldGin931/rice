defmodule RiceWeb.Api.TaskControllerTest do
  use RiceWeb.ConnCase, async: true

  test "公开读取任务，写动作需要登录和发布权限", %{conn: conn} do
    publisher = task_publisher_fixture()
    task = task_fixture(publisher, %{title: "村史整理"})

    assert %{"data" => [%{"id" => id, "status" => "open"}]} =
             conn |> get(~p"/api/tasks") |> json_response(200)

    assert id == task.id

    assert %{"data" => %{"allowed_actions" => []}} =
             build_conn() |> get(~p"/api/tasks/#{task.id}") |> json_response(200)

    {_user, token} = user_with_token()

    assert build_conn()
           |> authed(token)
           |> post(~p"/api/tasks", %{title: "越权", description: "不能发布"})
           |> json_response(403)
  end

  test "接口跑通申请、任命、提交、驳回与审核通过", %{conn: conn} do
    publisher = task_publisher_fixture()
    {:ok, publisher_token} = Rice.Accounts.issue_token(publisher)
    {worker, worker_token} = user_with_token()

    created =
      conn
      |> authed(publisher_token)
      |> post(~p"/api/tasks", %{title: "整理村史", description: "完成文字稿"})
      |> json_response(201)

    task_id = created["data"]["id"]

    applied =
      build_conn()
      |> authed(worker_token)
      |> post(~p"/api/tasks/#{task_id}/applications", %{reason: "有经验"})
      |> json_response(201)

    assert applied["data"]["my_application_status"] == "pending"

    detail =
      build_conn()
      |> authed(publisher_token)
      |> get(~p"/api/tasks/#{task_id}")
      |> json_response(200)

    application_id = hd(detail["data"]["applications"])["id"]

    appointed =
      build_conn()
      |> authed(publisher_token)
      |> post(~p"/api/tasks/#{task_id}/applications/#{application_id}/appoint")
      |> json_response(200)

    assert appointed["data"]["status"] == "in_progress"
    assert appointed["data"]["assignee"]["id"] == worker.id
    assert hd(appointed["data"]["applications"])["status"] == "appointed"

    assert %{"data" => []} =
             build_conn()
             |> authed(worker_token)
             |> get(~p"/api/tasks?mine=applied")
             |> json_response(200)

    assert %{"data" => [%{"id" => ^task_id}]} =
             build_conn()
             |> authed(worker_token)
             |> get(~p"/api/tasks?mine=assigned")
             |> json_response(200)

    submitted =
      build_conn()
      |> authed(worker_token)
      |> post(~p"/api/tasks/#{task_id}/submissions", %{body: "第一版"})
      |> json_response(201)

    submission_id = hd(submitted["data"]["submissions"])["id"]

    rejected =
      build_conn()
      |> authed(publisher_token)
      |> post(~p"/api/tasks/#{task_id}/submissions/#{submission_id}/request_changes", %{
        reason: "请补齐校对"
      })
      |> json_response(200)

    assert rejected["data"]["status"] == "in_progress"
    assert hd(rejected["data"]["submissions"])["review_reason"] == "请补齐校对"

    resubmitted =
      build_conn()
      |> authed(worker_token)
      |> post(~p"/api/tasks/#{task_id}/submissions", %{body: "补齐后的版本"})
      |> json_response(201)

    pending = Enum.find(resubmitted["data"]["submissions"], &(&1["status"] == "pending"))

    completed =
      build_conn()
      |> authed(publisher_token)
      |> post(~p"/api/tasks/#{task_id}/submissions/#{pending["id"]}/approve")
      |> json_response(200)

    assert completed["data"]["status"] == "completed"

    mine =
      build_conn()
      |> authed(worker_token)
      |> get(~p"/api/tasks?mine=assigned")
      |> json_response(200)

    assert Enum.map(mine["data"], & &1["id"]) == [task_id]
  end

  test "任务状态被推进后重复动作返回 409", %{conn: conn} do
    publisher = task_publisher_fixture()
    {:ok, publisher_token} = Rice.Accounts.issue_token(publisher)
    {worker, worker_token} = user_with_token()
    task = task_fixture(publisher)
    {:ok, application} = Rice.Tasks.apply(worker, task, %{})
    {:ok, _} = Rice.Tasks.appoint(publisher, task, application.id)

    assert conn
           |> authed(worker_token)
           |> post(~p"/api/tasks/#{task.id}/applications", %{})
           |> json_response(409)

    assert build_conn()
           |> authed(publisher_token)
           |> post(~p"/api/tasks/#{task.id}/applications/#{application.id}/appoint")
           |> json_response(409)
  end
end
