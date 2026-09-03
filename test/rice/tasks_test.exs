defmodule Rice.TasksTest do
  use Rice.DataCase, async: true

  alias Rice.Tasks

  test "任务奖励在发布时冻结，在认可结果时发给承作人" do
    publisher = task_publisher_fixture()
    worker = user_fixture()
    {:ok, _} = Rice.Grains.grant(publisher, 300, memo: "测试初始稻米")

    assert {:ok, task} =
             Tasks.create_task(publisher, %{
               title: "有奖励的任务",
               description: "完成后发放",
               reward_amount: 120
             })

    assert task.reward_status == "reserved"

    assert %{grain_balance: 180, grain_frozen_balance: 120} =
             Repo.get!(Rice.Accounts.User, publisher.id)

    assert {:ok, application} = Tasks.apply(worker, task, %{})
    assert {:ok, task} = Tasks.appoint(publisher, task, application.id)
    assert {:ok, task} = Tasks.submit_result(worker, task, %{body: "已完成"})
    submission = Enum.find(task.submissions, &is_nil(&1.review_reason))
    assert {:ok, completed} = Tasks.approve_result(publisher, task, submission.id)

    assert completed.reward_status == "settled"

    assert %{grain_balance: 180, grain_frozen_balance: 0} =
             Repo.get!(Rice.Accounts.User, publisher.id)

    assert %{grain_balance: 120} = Repo.get!(Rice.Accounts.User, worker.id)

    assert %{kind: "task_reward", amount: 120, subject_uri: subject_uri} =
             Repo.one!(from(t in Rice.Grains.Transfer, where: t.kind == "task_reward"))

    assert subject_uri == "rice://tasks/#{task.id}"
    assert Rice.Grains.reconcile().ok?
  end

  test "草稿不冻结，发布时才冻结；取消后自动退回" do
    publisher = task_publisher_fixture()
    {:ok, _} = Rice.Grains.grant(publisher, 200)

    assert {:ok, draft} =
             Tasks.create_task(publisher, %{
               title: "奖励草稿",
               description: "发布后冻结",
               status: "draft",
               reward_amount: 80
             })

    assert draft.reward_status == "none"

    assert %{grain_balance: 200, grain_frozen_balance: 0} =
             Repo.get!(Rice.Accounts.User, publisher.id)

    assert {:ok, task} = Tasks.publish_draft(publisher, draft)
    assert task.reward_status == "reserved"

    assert %{grain_balance: 120, grain_frozen_balance: 80} =
             Repo.get!(Rice.Accounts.User, publisher.id)

    assert {:ok, cancelled} = Tasks.cancel(publisher, task)
    assert cancelled.reward_status == "refunded"

    assert %{grain_balance: 200, grain_frozen_balance: 0} =
             Repo.get!(Rice.Accounts.User, publisher.id)

    assert Rice.Grains.reconcile().ok?
  end

  test "余额不足时任务发布与冻结一起回滚" do
    publisher = task_publisher_fixture()

    assert {:error, :insufficient_balance} =
             Tasks.create_task(publisher, %{
               title: "余额不足",
               description: "不能公开",
               reward_amount: 1
             })

    assert Repo.aggregate(Rice.Tasks.Task, :count) == 0
  end

  test "完整状态机保留驳回原因与承作人的完成历史" do
    publisher = task_publisher_fixture()
    worker = user_fixture()
    other = user_fixture()

    assert {:ok, task} =
             Tasks.create_task(publisher, %{title: "整理访谈", description: "完成文字稿"})

    assert task.status == "open"
    assert {:ok, application} = Tasks.apply(worker, task, %{reason: "有口述史经验"})
    assert {:ok, _} = Tasks.apply(other, task, %{reason: "也可以承做"})

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

    assert Enum.map(completed.events, &{&1.from_status, &1.to_status}) == [
             {nil, "open"},
             {"open", "in_progress"},
             {"in_progress", "under_review"},
             {"under_review", "in_progress"},
             {"in_progress", "under_review"},
             {"under_review", "completed"}
           ]

    assert Enum.find(
             completed.events,
             &(&1.from_status == "under_review" and &1.to_status == "in_progress")
           )
           |> Map.fetch!(:detail) == "缺少第二位受访者确认"

    assigned = Tasks.list_tasks(worker, %{"mine" => "assigned"}).entries
    assert Enum.map(assigned, & &1.id) == [completed.id]

    assert MapSet.new(Enum.map(Tasks.list_notifications(worker), & &1.event)) ==
             MapSet.new(~w(assignee_appointed changes_requested result_approved))

    assert [%{event: "application_not_selected"}] = Tasks.list_notifications(other)
    assert [not_selected] = Tasks.list_tasks(other, %{"mine" => "applied"}).entries
    assert not_selected.id == completed.id
    assert :ok = Tasks.mark_notifications_read(worker)
    assert Enum.all?(Tasks.list_notifications(worker), &match?(%DateTime{}, &1.read_at))
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

  test "任务取消通知所有申请人" do
    publisher = task_publisher_fixture()
    applicants = [user_fixture(), user_fixture()]
    task = task_fixture(publisher)

    Enum.each(applicants, fn user -> assert {:ok, _} = Tasks.apply(user, task, %{}) end)
    assert {:ok, %{status: "cancelled"}} = Tasks.cancel(publisher, task)

    Enum.each(applicants, fn user ->
      assert [%{event: "task_cancelled", actor_id: actor_id}] = Tasks.list_notifications(user)
      assert actor_id == publisher.id
      assert [history] = Tasks.list_tasks(user, %{"mine" => "applied"}).entries
      assert history.id == task.id
    end)
  end

  test "过期或状态已变化的旧快照不能再写入申请" do
    publisher = task_publisher_fixture()
    worker = user_fixture()
    task = task_fixture(publisher)

    assert {:ok, _cancelled} = Tasks.cancel(publisher, task)
    assert {:error, :conflict} = Tasks.apply(worker, task, %{})

    expiring = task_fixture(publisher)

    expiring
    |> change(application_deadline: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    assert {:error, :conflict} = Tasks.apply(worker, expiring, %{})
  end

  test "每位发布者只能保留一份草稿" do
    publisher = task_publisher_fixture()

    assert {:ok, _draft} =
             Tasks.create_task(publisher, %{
               title: "第一份草稿",
               description: "继续编辑这一份",
               status: "draft"
             })

    assert {:error, changeset} =
             Tasks.create_task(publisher, %{
               title: "第二份草稿",
               description: "不应创建",
               status: "draft"
             })

    assert Map.has_key?(errors_on(changeset), :creator_id)
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

    assert {:ok, task} =
             Tasks.create_task(publisher, %{title: "领取即将截止", description: "测试自动失效"})

    assert {:ok, _application} = Tasks.apply(worker, task, %{})

    task =
      task
      |> change(application_deadline: DateTime.add(DateTime.utc_now(), -1, :second))
      |> Repo.update!()

    assert %{expired: 1} = Tasks.expire_due_tasks()
    assert {:ok, expired} = Tasks.fetch_task(task.id, worker)
    assert expired.status == "expired"
    assert Enum.map(expired.events, & &1.to_status) == ["open", "expired"]
    assert {:error, :conflict} = Tasks.apply(worker, expired, %{})
    assert [%{event: "task_expired"}] = Tasks.list_notifications(worker)
    assert [history] = Tasks.list_tasks(worker, %{"mine" => "applied"}).entries
    assert history.id == task.id
    assert :ok = Rice.Workers.ExpireTasks.perform(%Oban.Job{args: %{}})
  end

  test "有奖励的任务失效后退回冻结稻米" do
    publisher = task_publisher_fixture()
    {:ok, _} = Rice.Grains.grant(publisher, 100)

    assert {:ok, task} =
             Tasks.create_task(publisher, %{
               title: "到期退回",
               description: "无人领取",
               reward_amount: 70
             })

    task
    |> change(application_deadline: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    assert %{expired: 1} = Tasks.expire_due_tasks()
    assert %{reward_status: "refunded"} = Repo.get!(Rice.Tasks.Task, task.id)

    assert %{grain_balance: 100, grain_frozen_balance: 0} =
             Repo.get!(Rice.Accounts.User, publisher.id)
  end

  test "任务列表支持后端关键词和结束状态筛选" do
    publisher = task_publisher_fixture()
    matching = task_fixture(publisher, %{title: "古村门楼测绘", description: "整理尺寸"})
    _other = task_fixture(publisher, %{title: "村播剪辑", description: "整理素材"})

    assert [result] = Tasks.list_tasks(nil, %{"q" => "门楼"}).entries
    assert result.id == matching.id

    assert {:ok, _cancelled} = Tasks.cancel(publisher, matching)
    assert [closed] = Tasks.list_tasks(nil, %{"status" => "closed"}).entries
    assert closed.id == matching.id
  end
end
