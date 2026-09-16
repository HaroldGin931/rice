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
    assert {:ok, one} = Events.apply(ctx.first, event, %{reason: "私人申请资料"})
    assert {:ok, two} = Events.apply(ctx.second, event, %{})
    assert length(two.applications) == 2
    assert balances(ctx.first) == {80, 20}
    assert balances(ctx.second) == {80, 20}
    assert {:ok, repeat} = Events.apply(ctx.first, event, %{})
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
    assert {:error, :insufficient_balance} = Events.apply(user, event, %{})
    assert Repo.aggregate(Application, :count) == 0
    assert Repo.aggregate(EventHistory, :count) == before
    assert balances(user) == {0, 0}
  end

  test "拒绝和移除分别退款且释放名额，重试不重复退，拒绝后不重报", ctx do
    event = event!(ctx)
    {:ok, event} = Events.apply(ctx.first, event, %{})
    {:ok, event} = Events.apply(ctx.second, event, %{})
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
    assert {:ok, revisit} = Events.apply(ctx.first, event, %{})
    assert application(revisit, ctx.first).status == "removed"

    another = event!(ctx)
    {:ok, another} = Events.apply(ctx.first, another, %{})
    a = application(another, ctx.first)
    assert {:ok, _} = Events.reject_application(ctx.host, another, a.id)
    assert {:ok, repeat} = Events.apply(ctx.first, another, %{})
    assert application(repeat, ctx.first).status == "rejected"
    assert balances(ctx.first) == {100, 0}
    assert Rice.Grains.reconcile().ok?
  end

  test "截止只关闭新申请，开始自动退未入选，结束须主办方确认才结算", ctx do
    event = event!(ctx)
    {:ok, event} = Events.apply(ctx.first, event, %{})
    {:ok, event} = Events.apply(ctx.second, event, %{})
    a = application(event, ctx.first)
    b = application(event, ctx.second)

    Repo.update_all(from(e in Event, where: e.id == ^event.id),
      set: [application_deadline: DateTime.add(DateTime.utc_now(), -1)]
    )

    assert {:ok, _} = Events.approve_application(ctx.host, event, a.id)
    assert {:error, :conflict} = Events.apply(user_fixture(), event, %{})
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
    assert balances(ctx.host) == {20, 0}
    assert {:error, :conflict} = Events.cancel(ctx.host, event)
    assert {:error, :conflict} = Events.remove_application(ctx.host, event, a.id)
    assert Rice.Grains.reconcile().ok?
  end

  test "退款异常回滚整场开始，恢复原冻结后系统原任务可重试", ctx do
    event = event!(ctx)
    {:ok, event} = Events.apply(ctx.first, event, %{})
    {:ok, event} = Events.apply(ctx.second, event, %{})
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
    {:ok, event} = Events.apply(ctx.first, event, %{})
    {:ok, event} = Events.apply(ctx.second, event, %{})
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
    {:ok, event} = Events.apply(ctx.first, event, %{reason: "私人甲"})
    {:ok, event} = Events.apply(ctx.second, event, %{reason: "私人乙"})
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

  defp attrs(node, extra \\ %{}) do
    now = DateTime.utc_now()

    Map.merge(
      %{
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
