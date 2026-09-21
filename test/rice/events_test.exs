defmodule Rice.EventsTest do
  use Rice.DataCase, async: true
  alias Rice.Events
  alias Rice.Events.{Application, Event, EventHistory}

  setup do
    host = user_fixture()
    node = node_fixture(%{user_id: host.id})
    first = user_fixture()
    second = user_fixture()
    for user <- [first, second], do: Rice.Grains.grant(user, 100)
    %{host: host, node: node, first: first, second: second}
  end

  test "草稿和发布重试复用原记录，只有节点管理员能发布", ctx do
    attrs = attrs(ctx.node, %{status: "draft"}) |> Map.delete(:client_request_id)
    assert {:ok, draft} = Events.create_event(ctx.host, attrs)
    assert {:ok, same} = Events.create_event(ctx.host, Map.put(attrs, :title, "新标题"))
    assert same.id == draft.id
    assert same.title == "新标题"
    assert {:ok, event} = Events.publish_draft(ctx.host, same)
    assert {:ok, again} = Events.publish_draft(ctx.host, draft)
    assert again.id == event.id
    assert event.status == "open"
    assert {:error, :conflict} = Events.update_draft(ctx.host, draft, %{fee_amount: 1})
    assert {:error, :forbidden} = Events.create_event(ctx.first, attrs(ctx.node))
    direct = attrs(ctx.node)
    assert {:ok, once} = Events.create_event(ctx.host, direct)
    assert {:ok, twice} = Events.create_event(ctx.host, direct)
    assert once.id == twice.id
    assert {:error, :not_found} = Events.fetch_event("not-an-id")
  end

  test "所有候选均可申请，冻结不占名额，通过时才检查容量", ctx do
    event = event!(ctx)
    assert {:ok, one} = Events.apply(ctx.first, event, %{contact: "测试联系方式", reason: "私人申请资料"})
    assert {:ok, two} = Events.apply(ctx.second, event, %{contact: "测试联系方式"})
    assert length(two.applications) == 2
    assert balances(ctx.first) == {80, 20}
    assert balances(ctx.second) == {80, 20}
    assert {:ok, repeat} = Events.apply(ctx.first, event, %{contact: "测试联系方式"})
    assert length(repeat.applications) == 2
    assert balances(ctx.first) == {80, 20}
    a = application(one, ctx.first)
    b = application(two, ctx.second)
    assert {:error, :forbidden} = Events.approve_application(ctx.second, event, a.id)
    assert {:ok, _} = Events.approve_application(ctx.host, event, a.id)
    assert {:error, :capacity_full} = Events.approve_application(ctx.host, event, b.id)
    assert {:ok, _} = Events.approve_application(ctx.host, event, a.id)
    assert Repo.get!(Application, b.id).status == "pending"
    assert Rice.Grains.reconcile().ok?
  end

  test "余额不足不会产生申请、冻结和进展的半成功记录", ctx do
    user = user_fixture()
    event = event!(ctx)
    before = Repo.aggregate(EventHistory, :count)
    assert {:error, :insufficient_balance} = Events.apply(user, event, %{contact: "测试联系方式"})
    assert Repo.aggregate(Application, :count) == 0
    assert Repo.aggregate(EventHistory, :count) == before
    assert balances(user) == {0, 0}
  end

  test "拒绝和移除分别退款且释放名额，重试不重复退，拒绝后不重报", ctx do
    event = event!(ctx)
    {:ok, event} = Events.apply(ctx.first, event, %{contact: "测试联系方式"})
    {:ok, event} = Events.apply(ctx.second, event, %{contact: "测试联系方式"})
    a = application(event, ctx.first)
    b = application(event, ctx.second)
    assert {:ok, _} = Events.approve_application(ctx.host, event, a.id)
    assert {:ok, _} = Events.remove_application(ctx.host, event, a.id)
    assert {:ok, _} = Events.remove_application(ctx.host, event, a.id)
    assert balances(ctx.first) == {100, 0}
    assert {:ok, _} = Events.approve_application(ctx.host, event, b.id)
    assert {:ok, _} = Events.cancel(ctx.host, event)
    assert {:ok, _} = Events.cancel(ctx.host, event)
    assert balances(ctx.second) == {100, 0}
    assert {:error, :conflict} = Events.finish(ctx.host, event)
    assert {:ok, revisit} = Events.apply(ctx.first, event, %{contact: "测试联系方式"})
    assert application(revisit, ctx.first).status == "removed"

    another = event!(ctx)
    {:ok, another} = Events.apply(ctx.first, another, %{contact: "测试联系方式"})
    a = application(another, ctx.first)
    assert {:ok, _} = Events.reject_application(ctx.host, another, a.id)
    assert {:ok, repeat} = Events.apply(ctx.first, another, %{contact: "测试联系方式"})
    assert application(repeat, ctx.first).status == "rejected"
    assert balances(ctx.first) == {100, 0}
    assert Rice.Grains.reconcile().ok?
  end

  test "截止只关闭新申请，开始自动退未入选，结束须主办方确认才结算", ctx do
    event = event!(ctx)
    {:ok, event} = Events.apply(ctx.first, event, %{contact: "测试联系方式"})
    {:ok, event} = Events.apply(ctx.second, event, %{contact: "测试联系方式"})
    a = application(event, ctx.first)
    b = application(event, ctx.second)

    Repo.update_all(from(e in Event, where: e.id == ^event.id),
      set: [application_deadline: DateTime.add(DateTime.utc_now(), -1)]
    )

    assert {:ok, _} = Events.approve_application(ctx.host, event, a.id)
    assert {:error, :conflict} = Events.apply(user_fixture(), event, %{contact: "测试联系方式"})
    assert {:error, :conflict} = Events.finish(ctx.host, event)
    age_event!(event)
    assert :ok = Events.start_due_events()
    assert :ok = Events.start_due_events()
    assert Repo.get!(Event, event.id).status == "in_progress"
    assert Repo.get!(Application, b.id).status == "not_selected"
    assert balances(ctx.first) == {80, 20}
    assert balances(ctx.second) == {100, 0}
    assert balances(ctx.host) == {0, 0}
    assert {:error, :conflict} = Events.approve_application(ctx.host, event, b.id)
    assert {:ok, finished} = Events.finish(ctx.host, event)
    assert {:ok, _} = Events.finish(ctx.host, event)
    assert finished.status == "completed"
    assert application(finished, ctx.first).payment_status == "settled"
    assert balances(ctx.first) == {80, 0}
    assert balances(ctx.host) == {0, 0}
    assert Repo.get!(Rice.Community.Node, ctx.node.id).grain_balance == 20
    assert {:error, :conflict} = Events.cancel(ctx.host, event)
    assert {:error, :conflict} = Events.remove_application(ctx.host, event, a.id)
    assert Rice.Grains.reconcile().ok?
  end

  test "退款异常回滚整场开始，恢复原冻结后系统原任务可重试", ctx do
    event = event!(ctx)
    {:ok, event} = Events.apply(ctx.first, event, %{contact: "测试联系方式"})
    {:ok, event} = Events.apply(ctx.second, event, %{contact: "测试联系方式"})
    users = Enum.sort_by([ctx.first, ctx.second], & &1.id)
    [healthy, broken] = users

    Repo.update_all(from(u in Rice.Accounts.User, where: u.id == ^broken.id),
      set: [grain_frozen_balance: 0]
    )

    age_event!(event)
    assert {:error, _} = Events.start_due_events()
    assert Repo.get!(Event, event.id).status == "open"
    assert balances(healthy) == {80, 20}
    assert Enum.all?(Repo.all(Application), &(&1.status == "pending"))
    assert {:error, _} = Events.finish(ctx.host, event)
    assert balances(ctx.host) == {0, 0}

    Repo.update_all(from(u in Rice.Accounts.User, where: u.id == ^broken.id),
      set: [grain_frozen_balance: 20]
    )

    assert :ok = Events.start_due_events()
    assert balances(healthy) == {100, 0}
    assert balances(broken) == {100, 0}
    assert Rice.Grains.reconcile().ok?
  end

  test "免费活动执行相同审批和开始规则，完全不产生资金操作", ctx do
    event = event!(ctx, %{fee_amount: 0})
    {:ok, event} = Events.apply(ctx.first, event, %{contact: "测试联系方式"})
    {:ok, event} = Events.apply(ctx.second, event, %{contact: "测试联系方式"})
    a = application(event, ctx.first)
    assert {:ok, _} = Events.approve_application(ctx.host, event, a.id)
    age_event!(event)
    # finish also performs overdue start before settlement, without relying on reads.
    assert {:ok, finished} = Events.finish(ctx.host, event)
    assert application(finished, ctx.first).payment_status == "none"
    assert application(finished, ctx.second).status == "not_selected"
    assert balances(ctx.first) == {100, 0}
    assert balances(ctx.second) == {100, 0}
    assert balances(ctx.host) == {0, 0}

    assert Repo.aggregate(
             from(t in Rice.Grains.Transfer,
               where: like(t.subject_uri, "rice://event_applications/%")
             ),
             :count
           ) == 0
  end

  test "公开详情隐藏候选理由和余额，本人仅见本人申请，主办方见全部", ctx do
    event = event!(ctx)
    {:ok, event} = Events.apply(ctx.first, event, %{contact: "测试联系方式", reason: "私人甲"})
    {:ok, event} = Events.apply(ctx.second, event, %{contact: "测试联系方式", reason: "私人乙"})
    public = RiceWeb.Api.EventJSON.show(%{event: event, current_user: nil}).data
    own = RiceWeb.Api.EventJSON.show(%{event: event, current_user: ctx.first}).data
    host = RiceWeb.Api.EventJSON.show(%{event: event, current_user: ctx.host}).data
    assert public.applications == []
    assert public.my_application == nil
    refute inspect(public) =~ "私人"
    refute inspect(public) =~ "grain_balance"
    assert Enum.map(own.applications, & &1.user.id) == [ctx.first.id]
    assert own.my_application.reason == "私人甲"
    assert length(host.applications) == 2
    assert Events.list_events(ctx.first, %{"mine" => "applied"}).entries |> length() == 1
  end

  test "本人可在报名截止后开始前撤销，退回原费用且不能重报或重复退款", ctx do
    event = event!(ctx)
    {:ok, event} = Events.apply(ctx.first, event, %{contact: "测试联系方式"})
    own = application(event, ctx.first)

    event
    |> Ecto.Changeset.change(application_deadline: DateTime.add(DateTime.utc_now(), -1))
    |> Repo.update!()

    assert {:ok, event} = Events.fetch_event(event.id, ctx.first)
    assert Events.application_actions(event, own, ctx.first) == ["withdraw"]
    assert balances(ctx.first) == {80, 20}
    assert {:ok, withdrawn} = Events.withdraw_application(ctx.first, event, own.id)
    assert withdrawn.status == "open"
    assert application(withdrawn, ctx.first).status == "withdrawn"
    assert application(withdrawn, ctx.first).payment_status == "refunded"
    assert balances(ctx.first) == {100, 0}

    assert Events.application_actions(withdrawn, application(withdrawn, ctx.first), ctx.first) ==
             []

    refute "apply" in Events.allowed_actions(withdrawn, ctx.first)

    assert {:ok, _} = Events.withdraw_application(ctx.first, event, own.id)
    assert {:ok, repeated} = Events.apply(ctx.first, event, %{contact: "测试联系方式"})
    assert application(repeated, ctx.first).id == own.id
    assert application(repeated, ctx.first).status == "withdrawn"
    assert {:error, :conflict} = Events.approve_application(ctx.host, event, own.id)
    assert {:ok, _} = Events.cancel(ctx.host, event)
    assert {:ok, _} = Events.withdraw_application(ctx.first, event, own.id)
    assert balances(ctx.first) == {100, 0}
    uri = "rice://event_applications/#{own.id}"

    assert Repo.aggregate(
             from(r in Rice.Grains.Receipt, where: r.subject_uri == ^uri and r.kind == "refunded"),
             :count
           ) == 1

    assert Repo.aggregate(
             from(h in EventHistory,
               where: h.application_id == ^own.id and h.action == "application_withdrawn"
             ),
             :count
           ) == 1

    assert Repo.aggregate(
             from(n in Rice.Tasks.Notification,
               where: n.subject_id == ^event.id and n.event == "event_application_withdrawn"
             ),
             :count
           ) == 1

    assert Rice.Grains.reconcile().ok?
  end

  test "免费申请撤销不产生冻结或退款凭证", ctx do
    event = event!(ctx, %{fee_amount: 0})
    {:ok, event} = Events.apply(ctx.first, event, %{contact: "测试联系方式"})
    own = application(event, ctx.first)
    assert {:ok, withdrawn} = Events.withdraw_application(ctx.first, event, own.id)
    assert application(withdrawn, ctx.first).status == "withdrawn"
    assert application(withdrawn, ctx.first).payment_status == "none"
    assert balances(ctx.first) == {100, 0}
    assert Repo.aggregate(Rice.Grains.Receipt, :count) == 0
  end

  test "只能撤销本人且属于本场的申请，主办者不能代撤销", ctx do
    event = event!(ctx)
    {:ok, event} = Events.apply(ctx.first, event, %{contact: "测试联系方式"})
    own = application(event, ctx.first)
    other_event = event!(ctx)

    assert {:error, :forbidden} = Events.withdraw_application(ctx.second, event, own.id)
    assert {:error, :forbidden} = Events.withdraw_application(ctx.host, event, own.id)
    assert {:error, :not_found} = Events.withdraw_application(ctx.first, other_event, own.id)
    assert {:error, :not_found} = Events.withdraw_application(ctx.first, event, "invalid")

    assert {:error, :not_found} =
             Events.withdraw_application(ctx.first, event, Rice.Tsid.generate())

    assert Repo.get!(Application, own.id).status == "pending"
    assert balances(ctx.first) == {80, 20}
  end

  test "已通过或其他已结束申请不能自助撤销", ctx do
    for action <- [:approved, :removed, :rejected, :cancelled, :not_selected] do
      event = event!(ctx, %{fee_amount: 0})
      {:ok, event} = Events.apply(ctx.first, event, %{contact: "测试联系方式"})
      own = application(event, ctx.first)

      case action do
        :approved ->
          assert {:ok, _} = Events.approve_application(ctx.host, event, own.id)

        :removed ->
          assert {:ok, _} = Events.approve_application(ctx.host, event, own.id)
          assert {:ok, _} = Events.remove_application(ctx.host, event, own.id)

        :rejected ->
          assert {:ok, _} = Events.reject_application(ctx.host, event, own.id)

        :cancelled ->
          assert {:ok, _} = Events.cancel(ctx.host, event)

        :not_selected ->
          assert {:ok, _} = Events.start_event(event.id, event.starts_at)
      end

      assert {:error, :conflict} = Events.withdraw_application(ctx.first, event, own.id)
      assert {:ok, current} = Events.fetch_event(event.id, ctx.first)
      assert application(current, ctx.first).status == Atom.to_string(action)
      assert Events.application_actions(current, application(current, ctx.first), ctx.first) == []
    end
  end

  test "到达开始时间即不能撤销，尚未执行定时任务也不能绕过", ctx do
    event = event!(ctx)
    {:ok, event} = Events.apply(ctx.first, event, %{contact: "测试联系方式"})
    own = application(event, ctx.first)
    now = DateTime.utc_now()

    event
    |> Ecto.Changeset.change(application_deadline: DateTime.add(now, -1), starts_at: now)
    |> Repo.update!()

    assert {:error, :conflict} = Events.withdraw_application(ctx.first, event, own.id)
    assert {:ok, current} = Events.fetch_event(event.id, ctx.first)
    assert current.status == "open"
    assert application(current, ctx.first).status == "pending"
    assert Events.application_actions(current, application(current, ctx.first), ctx.first) == []
    assert balances(ctx.first) == {80, 20}

    assert {:ok, _} = Events.start_event(event.id)
    assert Repo.get!(Application, own.id).status == "not_selected"
    assert balances(ctx.first) == {100, 0}
  end

  test "撤销退款失败时不写半成功状态或历史", ctx do
    event = event!(ctx)
    {:ok, event} = Events.apply(ctx.first, event, %{contact: "测试联系方式"})
    own = application(event, ctx.first)
    uri = "rice://event_applications/#{own.id}"
    Repo.delete_all(from(r in Rice.Grains.Receipt, where: r.subject_uri == ^uri))

    assert {:error, :grain_reservation_missing} =
             Events.withdraw_application(ctx.first, event, own.id)

    assert Repo.get!(Application, own.id).status == "pending"
    assert Repo.get!(Application, own.id).payment_status == "reserved"
    assert balances(ctx.first) == {80, 20}

    refute Repo.exists?(
             from(h in EventHistory,
               where: h.application_id == ^own.id and h.action == "application_withdrawn"
             )
           )
  end

  defp attrs(node, extra \\ %{}) do
    now = DateTime.utc_now()

    Map.merge(
      %{
        organizer_contact: "社区服务台",
        node_id: node.id,
        client_request_id: "event-#{System.unique_integer([:positive])}",
        title: "社区活动",
        description: "一起整理公共空间",
        location: "公共客厅",
        fee_amount: 20,
        capacity: 1,
        application_deadline: DateTime.add(now, 1800),
        starts_at: DateTime.add(now, 3600),
        ends_at: DateTime.add(now, 7200)
      },
      extra
    )
  end

  defp event!(ctx, extra \\ %{}) do
    {:ok, event} = Events.create_event(ctx.host, attrs(ctx.node, extra))
    event
  end

  defp application(event, user), do: Enum.find(event.applications, &(&1.user_id == user.id))

  defp balances(user) do
    current = Repo.get!(Rice.Accounts.User, user.id)
    {current.grain_balance, current.grain_frozen_balance}
  end

  defp age_event!(event) do
    now = DateTime.utc_now()

    Repo.update_all(from(e in Event, where: e.id == ^event.id),
      set: [
        application_deadline: DateTime.add(now, -30),
        starts_at: DateTime.add(now, -20),
        ends_at: DateTime.add(now, -10)
      ]
    )
  end
end
