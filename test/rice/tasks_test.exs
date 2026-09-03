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

    assert {:ok, task} =
             Tasks.appoint(publisher, task, application.id, %{
               appointment_reason: "相关经验最匹配"
             })

    assert task.status == "in_progress"
    assert task.assignee_id == worker.id
    assert task.appointment_reason == "相关经验最匹配"
    assert %DateTime{} = task.appointed_at
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

  test "公开列表可按任意用户的参与和发布记录筛选" do
    publisher = task_publisher_fixture()
    worker = user_fixture()
    other = user_fixture()
    task = task_fixture(publisher)
    other_task = task_fixture(task_publisher_fixture())

    assert {:ok, _draft} =
             Tasks.create_task(publisher, %{
               title: "未公开草稿",
               description: "不进入公开履历",
               status: "draft"
             })

    assert {:ok, _application} = Tasks.apply(worker, task, %{})
    assert {:ok, _application} = Tasks.apply(other, other_task, %{})

    participant_tasks =
      Tasks.list_tasks(nil, %{"participant_did" => worker.did}).entries

    created_tasks =
      Tasks.list_tasks(nil, %{"creator_did" => publisher.did}).entries

    assert Enum.map(participant_tasks, & &1.id) == [task.id]
    assert Enum.map(created_tasks, & &1.id) == [task.id]
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

  test "草稿只有发布者可见，发布后进入公开列表" do
    publisher = task_publisher_fixture()
    viewer = user_fixture()

    assert {:ok, draft} =
             Tasks.create_task(publisher, %{
               title: "尚未发布",
               description: "只对发布者可见",
               status: "draft"
             })

    assert draft.status == "draft"
    assert Tasks.list_tasks(nil).entries == []
    assert {:error, :not_found} = Tasks.fetch_task(draft.id, viewer)
    assert {:ok, _} = Tasks.fetch_task(draft.id, publisher)
    assert [mine] = Tasks.list_tasks(publisher, %{"mine" => "created"}).entries
    assert mine.id == draft.id

    assert {:error, :forbidden} =
             Tasks.update_draft(viewer, draft, %{title: "不该被修改"})

    assert {:ok, updated} =
             Tasks.update_draft(publisher, draft, %{
               title: "更新后的草稿",
               description: "仍然只对发布者可见"
             })

    assert updated.id == draft.id
    assert updated.title == "更新后的草稿"

    assert {:ok, published} = Tasks.publish_draft(publisher, updated)
    assert published.status == "open"
    assert [public] = Tasks.list_tasks(nil).entries
    assert public.id == draft.id
    assert {:error, :conflict} = Tasks.update_draft(publisher, published, %{title: "太晚了"})
  end

  test "发布者只能在任命前取消任务" do
    publisher = task_publisher_fixture()
    worker = user_fixture()
    task = task_fixture(publisher)

    assert {:error, :forbidden} = Tasks.cancel(worker, task)
    assert {:ok, cancelled} = Tasks.cancel(publisher, task)
    assert cancelled.status == "cancelled"
    assert {:error, :conflict} = Tasks.apply(worker, cancelled, %{})
  end

  test "领取截止后任务失效且不能继续申请" do
    publisher = task_publisher_fixture()
    worker = user_fixture()
    task = task_fixture(publisher)

    task =
      task
      |> change(application_deadline: DateTime.add(DateTime.utc_now(), -1, :second))
      |> Repo.update!()

    assert %{expired: 1} = Tasks.expire_due_tasks()
    assert {:ok, expired} = Tasks.fetch_task(task.id, worker)
    assert expired.status == "expired"
    assert {:error, :conflict} = Tasks.apply(worker, expired, %{})
    assert :ok = Rice.Workers.ExpireTasks.perform(%Oban.Job{args: %{}})
  end
end
