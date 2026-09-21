defmodule Rice.TasksTest do
  use Rice.DataCase, async: true

  alias Rice.Tasks

  test "任务奖励在发布时冻结，在认可结果时发给承作人" do
    publisher = task_publisher_fixture()
    worker = user_fixture()
    node = funded_node_fixture(publisher, 300)

    assert {:ok, task} =
             Tasks.create_task(publisher, %{
               organizer_contact: "社区服务台",
               title: "有奖励的任务",
               description: "完成后发放",
               reward_amount: 120
             })

    assert task.reward_status == "reserved"

    assert %{grain_balance: 180, grain_frozen_balance: 120} =
             Repo.get!(Rice.Community.Node, node.id)

    assert {:ok, application} = Tasks.apply(worker, task, %{contact: "测试联系方式"})
    assert {:ok, task} = Tasks.appoint(publisher, task, application.id)
    assert {:ok, task} = Tasks.submit_result(worker, task, %{body: "已完成"})
    submission = Enum.find(task.submissions, &is_nil(&1.review_reason))
    assert {:ok, completed} = Tasks.approve_result(publisher, task, submission.id)

    assert completed.reward_status == "settled"

    assert %{grain_balance: 180, grain_frozen_balance: 0} =
             Repo.get!(Rice.Community.Node, node.id)

    assert %{grain_balance: 120} = Repo.get!(Rice.Accounts.User, worker.id)

    assert %{kind: "task_reward", amount: 120, subject_uri: subject_uri} =
             Repo.one!(from(t in Rice.Grains.Transfer, where: t.kind == "task_reward"))

    assert subject_uri == "rice://tasks/#{task.id}"
    assert Rice.Grains.reconcile().ok?
  end

  test "草稿不冻结，发布时才冻结；取消后自动退回" do
    publisher = task_publisher_fixture()
    node = funded_node_fixture(publisher, 200)

    assert {:ok, draft} =
             Tasks.create_task(publisher, %{
               organizer_contact: "社区服务台",
               title: "奖励草稿",
               description: "发布后冻结",
               status: "draft",
               reward_amount: 80
             })

    assert draft.reward_status == "none"

    assert %{grain_balance: 200, grain_frozen_balance: 0} =
             Repo.get!(Rice.Community.Node, node.id)

    assert {:ok, task} = Tasks.publish_draft(publisher, draft)
    assert task.reward_status == "reserved"

    assert %{grain_balance: 120, grain_frozen_balance: 80} =
             Repo.get!(Rice.Community.Node, node.id)

    assert {:ok, cancelled} = Tasks.cancel(publisher, task)
    assert cancelled.reward_status == "refunded"

    assert %{grain_balance: 200, grain_frozen_balance: 0} =
             Repo.get!(Rice.Community.Node, node.id)

    assert Rice.Grains.reconcile().ok?
  end

  test "余额不足时任务发布与冻结一起回滚" do
    publisher = task_publisher_fixture()
    {:ok, _} = Rice.Grains.grant(publisher, 100)

    assert {:error, :insufficient_balance} =
             Tasks.create_task(publisher, %{
               organizer_contact: "社区服务台",
               title: "余额不足",
               description: "不能公开",
               reward_amount: 1
             })

    assert Repo.aggregate(Rice.Tasks.Task, :count) == 0
    assert %{balance: 100, frozen: 0} = Rice.Grains.wallet(publisher)
  end

  test "发布重读草稿，冻结当前金额并可按同一金额退款" do
    publisher = task_publisher_fixture()
    node = funded_node_fixture(publisher, 200)

    {:ok, stale_draft} =
      Tasks.create_task(publisher, %{
        organizer_contact: "社区服务台",
        title: "更新中的草稿",
        description: "发布时以当前约定为准",
        status: "draft",
        reward_amount: 80
      })

    assert {:ok, _} = Tasks.update_draft(publisher, stale_draft, %{reward_amount: 120})

    assert {:ok, published} = Tasks.publish_draft(publisher, stale_draft)
    assert published.reward_amount == 120

    assert %{grain_balance: 80, grain_frozen_balance: 120} =
             Repo.get!(Rice.Community.Node, node.id)

    assert %{amount: 120, kind: "reserved"} = Repo.one!(Rice.Grains.Receipt)
    assert {:ok, _} = Tasks.cancel(publisher, published)

    assert %{grain_balance: 200, grain_frozen_balance: 0} =
             Repo.get!(Rice.Community.Node, node.id)
  end

  test "草稿交付期限已过时不能发布，保留草稿且不冻结" do
    publisher = task_publisher_fixture()
    node = funded_node_fixture(publisher, 100)

    {:ok, stale_draft} =
      Tasks.create_task(publisher, %{
        organizer_contact: "社区服务台",
        title: "有交付期限的草稿",
        description: "过期应先修改",
        status: "draft",
        reward_amount: 60,
        execution_deadline: DateTime.add(DateTime.utc_now(), 60, :second)
      })

    stale_draft
    |> change(execution_deadline: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    assert {:error, changeset} = Tasks.publish_draft(publisher, stale_draft)
    assert Map.has_key?(errors_on(changeset), :execution_deadline)
    assert Repo.get!(Rice.Tasks.Task, stale_draft.id).status == "draft"

    assert %{grain_balance: 100, grain_frozen_balance: 0} =
             Repo.get!(Rice.Community.Node, node.id)

    assert Repo.aggregate(Rice.Grains.Receipt, :count) == 0
  end

  test "重复申请保留同一记录，不重复事件和通知" do
    publisher = task_publisher_fixture()
    worker = user_fixture()
    task = task_fixture(publisher)
    assert {:ok, first} = Tasks.apply(worker, task, %{contact: "测试联系方式", reason: "可以参与"})
    assert {:ok, repeated} = Tasks.apply(worker, task, %{contact: "测试联系方式", reason: "重试请求"})
    assert repeated.id == first.id
    assert repeated.reason == "可以参与"
    assert Repo.aggregate(Rice.Tasks.Application, :count) == 1
    assert Repo.aggregate(Rice.Tasks.Event, :count) == 1
    assert [%{event: "application_created"}] = Tasks.list_notifications(publisher)
  end

  test "完整状态机保留驳回原因与承作人的完成历史" do
    publisher = task_publisher_fixture()
    worker = user_fixture()
    other = user_fixture()

    assert {:ok, task} =
             Tasks.create_task(publisher, %{
               organizer_contact: "社区服务台",
               title: "整理访谈",
               description: "完成文字稿"
             })

    assert task.status == "open"
    assert {:ok, application} = Tasks.apply(worker, task, %{contact: "测试联系方式", reason: "有口述史经验"})
    assert {:ok, _} = Tasks.apply(other, task, %{contact: "测试联系方式", reason: "也可以承做"})

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
             {"open", "open"},
             {"open", "open"},
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

  test "只有社区唯一管理员可发布，管理员不能申请自己的任务" do
    user = user_fixture()

    assert {:error, :forbidden} =
             Tasks.create_task(user, %{
               organizer_contact: "社区服务台",
               title: "普通用户任务",
               description: "不能发布"
             })

    publisher = task_publisher_fixture()

    assert {:ok, task} =
             Tasks.create_task(publisher, %{
               organizer_contact: "社区服务台",
               title: "社区任务",
               description: "公开参与"
             })

    assert {:error, :forbidden} = Tasks.apply(publisher, task, %{contact: "测试联系方式"})

    assert {:error, :forbidden} =
             Tasks.create_task(user, %{
               organizer_contact: "社区服务台",
               title: "冒用社区",
               description: "不能发布",
               node_id: task.node_id
             })

    assert {:ok, _application} = Tasks.apply(user, task, %{contact: "测试联系方式"})
  end

  test "公开履历只列已承接任务，不暴露待选申请" do
    publisher = task_publisher_fixture()
    worker = user_fixture()
    other = user_fixture()
    task = task_fixture(publisher)
    other_task = task_fixture(task_publisher_fixture())

    assert {:ok, _draft} =
             Tasks.create_task(publisher, %{
               organizer_contact: "社区服务台",
               title: "未公开草稿",
               description: "不进入公开履历",
               status: "draft"
             })

    assert {:ok, application} = Tasks.apply(worker, task, %{contact: "测试联系方式"})
    assert {:ok, _application} = Tasks.apply(other, other_task, %{contact: "测试联系方式"})

    assert Tasks.list_tasks(nil, %{"participant_did" => worker.did}).entries == []
    assert {:ok, _appointed} = Tasks.appoint(publisher, task, application.id)

    participant_tasks =
      Tasks.list_tasks(nil, %{"participant_did" => worker.did}).entries

    created_tasks =
      Tasks.list_tasks(nil, %{"creator_did" => publisher.did}).entries

    assert Enum.map(participant_tasks, & &1.id) == [task.id]
    assert Enum.map(created_tasks, & &1.id) == [task.id]
    assert Tasks.list_tasks(nil, %{"participant_did" => other.did}).entries == []
  end

  test "驳回必须填写原因" do
    publisher = task_publisher_fixture()
    worker = user_fixture()
    task = task_fixture(publisher)
    {:ok, application} = Tasks.apply(worker, task, %{contact: "测试联系方式"})
    {:ok, task} = Tasks.appoint(publisher, task, application.id)
    {:ok, task} = Tasks.submit_result(worker, task, %{body: "已完成"})
    submission = Enum.find(task.submissions, &is_nil(&1.review_reason))

    assert {:error, changeset} = Tasks.request_changes(publisher, task, submission.id, "   ")
    assert Map.has_key?(errors_on(changeset), :review_reason)
  end

  test "新一轮交付不能被旧结果的验收或驳回请求推进" do
    publisher = task_publisher_fixture()
    worker = user_fixture()
    node = funded_node_fixture(publisher, 100)

    {:ok, task} =
      Tasks.create_task(publisher, %{
        organizer_contact: "社区服务台",
        title: "反复校对",
        description: "以本轮交付为准",
        reward_amount: 60
      })

    {:ok, application} = Tasks.apply(worker, task, %{contact: "测试联系方式"})
    {:ok, task} = Tasks.appoint(publisher, task, application.id)
    {:ok, first_review} = Tasks.submit_result(worker, task, %{body: "旧版本"})
    first_submission = Enum.find(first_review.submissions, &is_nil(&1.review_reason))
    {:ok, returned} = Tasks.request_changes(publisher, first_review, first_submission.id, "需要补充")
    {:ok, second_review} = Tasks.submit_result(worker, returned, %{body: "新版本"})
    second_submission = Enum.find(second_review.submissions, &is_nil(&1.review_reason))

    assert {:error, :conflict} =
             Tasks.approve_result(publisher, first_review, first_submission.id)

    assert {:error, :conflict} =
             Tasks.request_changes(publisher, first_review, first_submission.id, "迟到的旧驳回")

    assert Repo.get!(Rice.Tasks.Task, task.id).status == "under_review"
    assert is_nil(Repo.get!(Rice.Tasks.Submission, second_submission.id).review_reason)

    assert %{grain_balance: 40, grain_frozen_balance: 60} =
             Repo.get!(Rice.Community.Node, node.id)

    assert Repo.get!(Rice.Accounts.User, worker.id).grain_balance == 0
    assert {:ok, completed} = Tasks.approve_result(publisher, second_review, second_submission.id)
    assert completed.status == "completed"
    assert Repo.get!(Rice.Accounts.User, worker.id).grain_balance == 60
  end

  test "任务取消通知所有申请人" do
    publisher = task_publisher_fixture()
    applicants = [user_fixture(), user_fixture()]
    task = task_fixture(publisher)

    Enum.each(applicants, fn user ->
      assert {:ok, _} = Tasks.apply(user, task, %{contact: "测试联系方式"})
    end)

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
    assert {:error, :conflict} = Tasks.apply(worker, task, %{contact: "测试联系方式"})

    expiring = task_fixture(publisher)

    expiring
    |> change(application_deadline: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    assert {:error, :conflict} = Tasks.apply(worker, expiring, %{contact: "测试联系方式"})
  end

  test "每位发布者只能保留一份草稿" do
    publisher = task_publisher_fixture()

    assert {:ok, _draft} =
             Tasks.create_task(publisher, %{
               organizer_contact: "社区服务台",
               title: "第一份草稿",
               description: "继续编辑这一份",
               status: "draft"
             })

    assert {:error, changeset} =
             Tasks.create_task(publisher, %{
               organizer_contact: "社区服务台",
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
               organizer_contact: "社区服务台",
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
    assert {:error, :conflict} = Tasks.apply(worker, cancelled, %{contact: "测试联系方式"})
  end

  test "申请截止后停止新申请，已有候选仍可选定且截止记录不重复" do
    publisher = task_publisher_fixture()
    worker = user_fixture()

    assert {:ok, task} =
             Tasks.create_task(publisher, %{
               organizer_contact: "社区服务台",
               title: "申请即将截止",
               description: "保留已有候选"
             })

    assert {:ok, application} = Tasks.apply(worker, task, %{contact: "测试联系方式"})

    task =
      task
      |> change(application_deadline: DateTime.add(DateTime.utc_now(), -1, :second))
      |> Repo.update!()

    assert {:ok, _} = Tasks.check_due_tasks()
    assert {:ok, _} = Tasks.check_due_tasks()
    assert {:ok, closed} = Tasks.fetch_task(task.id, worker)
    assert closed.status == "open"
    assert Enum.count(closed.events, &(&1.detail == "申请已截止")) == 1
    assert Enum.all?(closed.events, &(&1.to_status == "open"))
    assert {:error, :conflict} = Tasks.apply(user_fixture(), closed, %{contact: "测试联系方式"})
    assert Tasks.list_notifications(worker) == []
    assert [history] = Tasks.list_tasks(worker, %{"mine" => "applied"}).entries
    assert history.id == task.id
    assert {:ok, appointed} = Tasks.appoint(publisher, closed, application.id)
    assert appointed.status == "in_progress"
    assert :ok = Rice.Workers.ExpireTasks.perform(%Oban.Job{args: %{}})
  end

  test "申请截止不解冻，执行逾期保留承接人和报酬" do
    publisher = task_publisher_fixture()
    node = funded_node_fixture(publisher, 100)

    assert {:ok, task} =
             Tasks.create_task(publisher, %{
               organizer_contact: "社区服务台",
               title: "到期保留",
               description: "保持原有约定",
               reward_amount: 70
             })

    worker = user_fixture()
    assert {:ok, application} = Tasks.apply(worker, task, %{contact: "测试联系方式"})

    task
    |> change(application_deadline: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    assert {:ok, _} = Tasks.check_due_tasks()
    assert %{status: "open", reward_status: "reserved"} = Repo.get!(Rice.Tasks.Task, task.id)

    assert %{grain_balance: 30, grain_frozen_balance: 70} =
             Repo.get!(Rice.Community.Node, node.id)

    # 已选人后的交付逾期只记录状态，不能自动取消或发放报酬。
    assert {:ok, assigned} = Tasks.appoint(publisher, task, application.id)

    assigned
    |> change(execution_deadline: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    assert {:ok, _} = Tasks.check_due_tasks()
    assert {:ok, _} = Tasks.check_due_tasks()
    assert {:ok, overdue} = Tasks.fetch_task(task.id, worker)
    assert overdue.status == "in_progress"
    assert overdue.assignee_id == worker.id
    assert Enum.count(overdue.events, &(&1.detail == "执行已逾期，请联系发布者协调")) == 1
    assert Enum.count(Tasks.list_notifications(worker), &(&1.event == "task_overdue")) == 1

    assert %{grain_balance: 30, grain_frozen_balance: 70} =
             Repo.get!(Rice.Community.Node, node.id)
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

  test "搜索按真实发布时间游标分页" do
    publisher = task_publisher_fixture()

    assert {:ok, draft} =
             Tasks.create_task(publisher, %{
               organizer_contact: "社区服务台",
               title: "同一搜索词的旧草稿",
               description: "稍后发布",
               status: "draft"
             })

    assert {:ok, older_public} =
             Tasks.create_task(publisher, %{
               organizer_contact: "社区服务台",
               title: "同一搜索词的公开任务",
               description: "直接发布"
             })

    assert {:ok, newer_public} = Tasks.publish_draft(publisher, draft)

    first =
      Tasks.list_tasks(nil, %{
        "q" => "同一搜索词",
        "sort" => "published",
        "limit" => "1"
      })

    assert Enum.map(first.entries, & &1.id) == [newer_public.id]
    assert is_binary(first.next_cursor)

    second =
      Tasks.list_tasks(nil, %{
        "q" => "同一搜索词",
        "sort" => "published",
        "limit" => "1",
        "before" => first.next_cursor
      })

    assert Enum.map(second.entries, & &1.id) == [older_public.id]
    assert second.next_cursor == nil
  end
end
