defmodule Rice.TasksTest do
  use Rice.DataCase, async: true

  alias Rice.Tasks

  test "完整状态机保留驳回原因与承作人的完成历史" do
    publisher = task_publisher_fixture()
    worker = user_fixture()

    assert {:ok, task} =
             Tasks.create_task(publisher, %{title: "整理访谈", description: "完成文字稿"})

    assert task.status == "open"
    assert {:ok, application} = Tasks.apply(worker, task, %{reason: "有口述史经验"})

    assert [pending] = Tasks.list_tasks(worker, %{"mine" => "applied"}).entries
    assert pending.id == task.id

    assert {:ok, task} = Tasks.appoint(publisher, task, application.id)
    assert task.status == "in_progress"
    assert task.assignee_id == worker.id
    assert Tasks.list_tasks(worker, %{"mine" => "applied"}).entries == []

    assert [assigned] = Tasks.list_tasks(worker, %{"mine" => "assigned"}).entries
    assert assigned.id == task.id

    assert {:ok, task} = Tasks.submit_result(worker, task, %{body: "第一版文字稿"})
    pending = Enum.find(task.submissions, &is_nil(&1.review_reason))
    assert task.status == "under_review"

    assert {:ok, task} =
             Tasks.request_changes(publisher, task, pending.id, "缺少第二位受访者确认")

    rejected = Enum.find(task.submissions, &(&1.id == pending.id))
    assert task.status == "in_progress"
    assert task.assignee_id == worker.id
    assert rejected.review_reason == "缺少第二位受访者确认"

    assert {:ok, task} = Tasks.submit_result(worker, task, %{body: "补齐后的文字稿"})
    resubmission = Enum.find(task.submissions, &is_nil(&1.review_reason))
    assert {:ok, completed} = Tasks.approve_result(publisher, task, resubmission.id)
    assert completed.status == "completed"

    assigned = Tasks.list_tasks(worker, %{"mine" => "assigned"}).entries
    assert Enum.map(assigned, & &1.id) == [completed.id]
  end

  test "普通用户不能发布，申请人不能申请自己的任务" do
    user = user_fixture()
    publisher = task_publisher_fixture()

    assert {:error, :forbidden} =
             Tasks.create_task(user, %{title: "越权", description: "不应创建"})

    task = task_fixture(publisher)
    assert {:error, :forbidden} = Tasks.apply(publisher, task, %{})
  end

  test "驳回必须填写原因" do
    publisher = task_publisher_fixture()
    worker = user_fixture()
    task = task_fixture(publisher)
    {:ok, application} = Tasks.apply(worker, task, %{})
    {:ok, task} = Tasks.appoint(publisher, task, application.id)
    {:ok, task} = Tasks.submit_result(worker, task, %{body: "已完成"})
    submission = Enum.find(task.submissions, &is_nil(&1.review_reason))

    assert {:error, changeset} = Tasks.request_changes(publisher, task, submission.id, "   ")
    assert Map.has_key?(errors_on(changeset), :review_reason)
  end
end
