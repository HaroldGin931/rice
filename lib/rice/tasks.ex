defmodule Rice.Tasks do
  @moduledoc """
  社区单人任务：草稿、发布、申请、任命、交付与验收。

  唯一管理员代表节点发布并出资；申请截止仅关闭新申请，原冻结款保留。
  """
  import Ecto.Query

  alias Ecto.Multi
  alias Rice.Accounts.User
  alias Rice.Tasks.{Application, Event, Notification, Submission, Task}
  alias Rice.{Grains, Pagination, Repo}

  def list_tasks(user, params \\ %{}) do
    query =
      from(t in Task, as: :task)
      |> scope_visibility(user, params["mine"])
      |> filter_status(params["status"])
      |> filter_query(params["q"])
      |> filter_node(params["node_id"])
      |> filter_available(user, params["available"])
      |> scope_public_user(params["participant_did"], params["creator_did"])
      |> scope_mine(user, params["mine"])

    page = paginate_tasks(query, params)

    %{page | entries: preload_list(page.entries)}
  end

  def fetch_task(id, user \\ nil) do
    with {:ok, task} <- fetch_task_record(id),
         true <- visible_to?(task, user) do
      {:ok, task}
    else
      false -> {:error, :not_found}
      error -> error
    end
  end

  defp fetch_task_record(id) do
    if Rice.Tsid.valid?(id) do
      case Repo.get(Task, id) do
        nil -> {:error, :not_found}
        task -> {:ok, preload_detail(task)}
      end
    else
      {:error, :not_found}
    end
  end

  def create_task(%User{} = user, attrs) do
    Repo.transaction(fn ->
      Repo.one!(from u in User, where: u.id == ^user.id, lock: "FOR UPDATE")

      with {:ok, node} <- publishing_node(user, attrs["node_id"] || attrs[:node_id]) do
        key = attrs["client_request_id"] || attrs[:client_request_id]

        existing =
          if is_binary(key) && key != "",
            do: Repo.get_by(Task, creator_id: user.id, client_request_id: key)

        if existing do
          preload_detail(existing)
        else
          case create_new_task(user, node, attrs) do
            {:ok, task} -> task
            {:error, reason} -> Repo.rollback(reason)
          end
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp publishing_node(user, nil) do
    case Repo.all(from n in Rice.Community.Node, where: n.user_id == ^user.id, limit: 2) do
      [node] -> {:ok, node}
      _ -> {:error, :forbidden}
    end
  end

  defp publishing_node(user, id) do
    if Rice.Tsid.valid?(id) do
      case Repo.get_by(Rice.Community.Node, id: id, user_id: user.id) do
        nil -> {:error, :forbidden}
        node -> {:ok, node}
      end
    else
      {:error, :forbidden}
    end
  end

  defp create_new_task(user, node, attrs) do
    with {:ok, status} <- initial_status(attrs) do
      # Do not wait on the draft unique index while holding the payer lock:
      # publishing that draft needs the same payer lock to reserve its reward.
      if status == "draft" and
           Repo.exists?(
             from t in Task,
               where: t.creator_id == ^user.id and t.status == "draft"
           ) do
        Repo.rollback(
          Ecto.Changeset.add_error(Ecto.Changeset.change(%Task{}), :creator_id, "已有草稿，请继续编辑")
        )
      end

      task_changeset =
        %Task{creator_id: user.id, node_id: node.id, status: status}
        |> Task.create_changeset(attrs)

      reward_amount = Ecto.Changeset.get_field(task_changeset, :reward_amount) || 0

      task_changeset =
        Ecto.Changeset.put_change(
          task_changeset,
          :reward_status,
          if(status == "open" and reward_amount > 0, do: "reserved", else: "none")
        )

      Multi.new()
      |> Multi.insert(:task, task_changeset)
      |> maybe_run_reward(
        if status == "open" and reward_amount > 0 do
          fn repo, %{task: task} ->
            Grains.reserve_business(repo, user.id, reward_amount, "rice://tasks/#{task.id}")
          end
        end
      )
      |> Multi.insert(:event, fn %{task: task} ->
        detail = if status == "open", do: reward_detail(task, :reserved)
        event_changeset(task.id, user.id, nil, status, detail)
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{task: task}} -> {:ok, preload_detail(task)}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    end
  end

  def update_draft(user, task, attrs) do
    with_locked_task(task.id, &update_current_draft(user, &1, attrs))
  end

  defp update_current_draft(
         %User{id: creator_id},
         %Task{creator_id: creator_id, status: "draft"} = task,
         attrs
       ) do
    attrs = Map.drop(attrs, ["client_request_id", :client_request_id])

    with {:ok, updated} <- task |> Task.create_changeset(attrs) |> Repo.update() do
      {:ok, preload_detail(updated)}
    end
  end

  defp update_current_draft(%User{id: creator_id}, %Task{creator_id: creator_id}, _attrs),
    do: {:error, :conflict}

  defp update_current_draft(%User{}, %Task{}, _attrs), do: {:error, :forbidden}

  def publish_draft(user, %Task{} = task) do
    with_locked_task(task.id, &publish_current_draft(user, &1))
  end

  defp publish_current_draft(
         %User{id: creator_id},
         %Task{creator_id: creator_id, status: "draft"} = task
       ) do
    with {:ok, _node} <- publishing_node(%User{id: creator_id}, task.node_id) do
      case Task.publish_changeset(task) do
        %{valid?: true} ->
          {updates, detail, reward_step} = reserve_reward(task)

          transition_task(
            from(t in Task, where: t.id == ^task.id and t.status == "draft"),
            task,
            updates,
            creator_id,
            detail,
            [],
            reward_step
          )

        changeset ->
          {:error, changeset}
      end
    end
  end

  defp publish_current_draft(
         %User{id: creator_id},
         %Task{creator_id: creator_id, status: "open"} = task
       ),
       do: {:ok, preload_detail(task)}

  defp publish_current_draft(%User{id: creator_id}, %Task{creator_id: creator_id}),
    do: {:error, :conflict}

  defp publish_current_draft(%User{}, %Task{}), do: {:error, :forbidden}

  def cancel(%User{id: creator_id}, %Task{creator_id: creator_id, status: status} = task)
      when status in ["open", "draft"] do
    {updates, detail, reward_step} = refund_reward(task, "cancelled")

    notifications =
      fn repo ->
        Enum.map(applicant_ids(repo, task.id), &{&1, creator_id, "task_cancelled", nil})
      end

    transition_task(
      from(t in Task, where: t.id == ^task.id and t.status == ^status),
      task,
      updates,
      creator_id,
      detail,
      notifications,
      reward_step
    )
  end

  def cancel(%User{id: creator_id}, %Task{creator_id: creator_id}), do: {:error, :conflict}
  def cancel(%User{}, %Task{}), do: {:error, :forbidden}

  def apply(%User{id: user_id}, %Task{creator_id: user_id}, _attrs),
    do: {:error, :forbidden}

  def apply(%User{} = user, %Task{status: "open"} = task, attrs) do
    now = DateTime.utc_now()

    application =
      Application.create_changeset(%Application{task_id: task.id, user_id: user.id}, attrs)

    Multi.new()
    |> Multi.run(:task, fn repo, _ -> lock_open_task(repo, task.id, now) end)
    |> Multi.run(:existing_application, fn repo, _ ->
      {:ok, repo.get_by(Application, task_id: task.id, user_id: user.id)}
    end)
    |> Multi.run(:application, fn repo, %{existing_application: existing} ->
      case existing do
        nil -> repo.insert(application)
        existing -> {:ok, existing}
      end
    end)
    |> Multi.run(:application_event, fn repo, %{existing_application: existing} ->
      if existing,
        do: {:ok, :already_applied},
        else: repo.insert(event_changeset(task.id, user.id, "open", "open", "收到任务申请"))
    end)
    |> Multi.run(:notification, fn repo, %{task: current_task, existing_application: existing} ->
      if existing,
        do: {:ok, :already_applied},
        else:
          repo.insert(
            notification_changeset(
              current_task,
              current_task.creator_id,
              user.id,
              "application_created"
            )
          )
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{application: application}} ->
        {:ok, Repo.preload(application, user: :avatar)}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  def apply(%User{}, %Task{}, _attrs), do: {:error, :conflict}

  def appoint(user, %Task{} = task, application_id, attrs \\ %{}) do
    with_locked_task(task.id, fn current ->
      with {:ok, application} <- fetch_record(Application, current.id, application_id) do
        appoint_application(user, current, application, attrs)
      end
    end)
  end

  def reject_application(user, %Task{} = task, application_id) do
    with_locked_task(task.id, fn current ->
      with {:ok, application} <- fetch_record(Application, current.id, application_id) do
        reject_current_application(user, current, application)
      end
    end)
  end

  defp reject_current_application(
         %User{id: creator_id},
         %Task{creator_id: creator_id, status: "open"} = task,
         %Application{} = application
       ) do
    if application.rejected_at do
      {:ok, preload_detail(task)}
    else
      with {:ok, _} <-
             application
             |> Ecto.Changeset.change(rejected_at: DateTime.utc_now())
             |> Repo.update(),
           {:ok, _} <-
             Repo.insert(
               notification_changeset(
                 task,
                 application.user_id,
                 creator_id,
                 "application_rejected"
               )
             ) do
        {:ok, preload_detail(task)}
      end
    end
  end

  defp reject_current_application(%User{id: id}, %Task{creator_id: id}, _application),
    do: {:error, :conflict}

  defp reject_current_application(%User{}, %Task{}, _application), do: {:error, :forbidden}

  defp appoint_application(
         %User{id: creator_id},
         %Task{creator_id: creator_id, status: "open"} = task,
         %Application{task_id: task_id, rejected_at: nil} = application,
         attrs
       )
       when task_id == task.id do
    changeset = Task.appointment_changeset(task, attrs)

    if changeset.valid? do
      appointment_reason = Ecto.Changeset.get_field(changeset, :appointment_reason)

      notifications =
        fn repo ->
          pending_ids =
            repo.all(
              from a in Application,
                where: a.task_id == ^task.id and is_nil(a.rejected_at),
                select: a.user_id
            )

          Enum.map(pending_ids, fn user_id ->
            if user_id == application.user_id,
              do: {user_id, creator_id, "assignee_appointed", appointment_reason},
              else: {user_id, creator_id, "application_not_selected", nil}
          end)
        end

      transition_task(
        from(t in Task, where: t.id == ^task.id and t.status == "open"),
        task,
        [
          status: "in_progress",
          assignee_id: application.user_id,
          appointed_at: DateTime.utc_now(),
          appointment_reason: appointment_reason
        ],
        creator_id,
        appointment_reason,
        notifications
      )
    else
      {:error, changeset}
    end
  end

  defp appoint_application(
         %User{id: creator_id},
         %Task{creator_id: creator_id},
         %Application{},
         _attrs
       ),
       do: {:error, :conflict}

  defp appoint_application(%User{}, %Task{}, %Application{}, _attrs), do: {:error, :forbidden}

  def submit_result(
        %User{id: user_id},
        %Task{assignee_id: user_id, status: "in_progress"} = task,
        attrs
      ) do
    now = DateTime.utc_now()

    changeset =
      Submission.create_changeset(%Submission{task_id: task.id, user_id: user_id}, attrs)

    Multi.new()
    |> Multi.run(:task, fn repo, _ ->
      conditional_update(
        repo,
        from(t in Task,
          where: t.id == ^task.id and t.status == "in_progress" and t.assignee_id == ^user_id
        ),
        status: "under_review",
        updated_at: now
      )
    end)
    |> Multi.insert(
      :event,
      event_changeset(task.id, user_id, "in_progress", "under_review")
    )
    |> Multi.insert(:submission, changeset)
    |> Multi.insert(
      :notification,
      notification_changeset(task, task.creator_id, user_id, "result_submitted")
    )
    |> Repo.transaction()
    |> transaction_task(task.id)
  end

  def submit_result(%User{id: user_id}, %Task{assignee_id: user_id}, _attrs),
    do: {:error, :conflict}

  def submit_result(%User{}, %Task{}, _attrs), do: {:error, :forbidden}

  def approve_result(user, %Task{} = task, submission_id) do
    with_locked_task(task.id, fn current_task ->
      with {:ok, submission} <- fetch_record(Submission, current_task.id, submission_id) do
        approve_submission(user, current_task, submission)
      end
    end)
  end

  defp approve_submission(
         %User{id: creator_id},
         %Task{creator_id: creator_id, status: "under_review"} = task,
         %Submission{task_id: task_id, review_reason: nil} = submission
       )
       when task_id == task.id do
    {updates, detail, reward_step} = settle_reward(task, submission.user_id)

    transition_task(
      from(t in Task, where: t.id == ^task.id and t.status == "under_review"),
      task,
      updates,
      creator_id,
      detail,
      [{submission.user_id, creator_id, "result_approved", detail}],
      reward_step
    )
  end

  defp approve_submission(%User{id: creator_id}, %Task{creator_id: creator_id}, %Submission{}),
    do: {:error, :conflict}

  defp approve_submission(%User{}, %Task{}, %Submission{}), do: {:error, :forbidden}

  def request_changes(user, %Task{} = task, submission_id, reason) do
    with_locked_task(task.id, fn current_task ->
      with {:ok, submission} <- fetch_record(Submission, current_task.id, submission_id) do
        request_submission_changes(user, current_task, submission, reason)
      end
    end)
  end

  defp request_submission_changes(
         %User{id: creator_id},
         %Task{creator_id: creator_id, status: "under_review"} = task,
         %Submission{task_id: task_id, review_reason: nil} = submission,
         reason
       )
       when task_id == task.id and is_binary(reason) do
    changeset = Submission.review_changeset(submission, reason)

    if changeset.valid? do
      now = DateTime.utc_now()

      Multi.new()
      |> Multi.run(:task, fn repo, _ ->
        conditional_update(
          repo,
          from(t in Task, where: t.id == ^task.id and t.status == "under_review"),
          status: "in_progress",
          updated_at: now
        )
      end)
      |> Multi.insert(
        :event,
        event_changeset(task.id, creator_id, "under_review", "in_progress", reason)
      )
      |> Multi.update(:submission, changeset)
      |> Multi.insert(
        :notification,
        notification_changeset(task, submission.user_id, creator_id, "changes_requested", reason)
      )
      |> Repo.transaction()
      |> transaction_task(task.id)
    else
      {:error, changeset}
    end
  end

  defp request_submission_changes(
         %User{id: creator_id},
         %Task{creator_id: creator_id},
         %Submission{},
         _
       ),
       do: {:error, :conflict}

  defp request_submission_changes(%User{}, %Task{}, %Submission{}, _),
    do: {:error, :forbidden}

  def check_due_tasks(now \\ DateTime.utc_now()) do
    due = from(t in Task, where: t.status in ["open", "in_progress", "under_review"])

    Repo.transaction(fn ->
      for task <- Repo.all(from t in due, lock: "FOR UPDATE SKIP LOCKED") do
        detail =
          cond do
            (task.status == "open" and task.application_deadline) &&
                DateTime.compare(task.application_deadline, now) != :gt ->
              "申请已截止"

            (task.status in ["in_progress", "under_review"] and task.execution_deadline) &&
                DateTime.compare(task.execution_deadline, now) != :gt ->
              "执行已逾期，请联系发布者协调"

            true ->
              nil
          end

        if detail &&
             not Repo.exists?(
               from e in Event, where: e.task_id == ^task.id and e.detail == ^detail
             ) do
          Repo.insert!(event_changeset(task.id, nil, task.status, task.status, detail))

          if task.assignee_id,
            do:
              Repo.insert!(
                notification_changeset(
                  task,
                  task.assignee_id,
                  task.creator_id,
                  "task_overdue",
                  detail
                )
              )
        end
      end
    end)
  end

  def list_notifications(%User{id: user_id}) do
    from(n in Notification,
      where: n.recipient_id == ^user_id and not is_nil(n.task_id),
      order_by: [desc: n.id],
      limit: 50,
      preload: [actor: :avatar, task: []]
    )
    |> Repo.all()
  end

  def mark_notifications_read(%User{id: user_id}) do
    Repo.update_all(
      from(n in Notification, where: n.recipient_id == ^user_id and is_nil(n.read_at)),
      set: [read_at: DateTime.utc_now(), updated_at: DateTime.utc_now()]
    )

    :ok
  end

  defp initial_status(attrs) do
    case attrs["status"] || attrs[:status] do
      nil -> {:ok, "open"}
      "draft" -> {:ok, "draft"}
      "open" -> {:ok, "open"}
      _ -> {:error, :unprocessable_entity}
    end
  end

  defp visible_to?(%Task{status: "draft", creator_id: creator_id}, %User{id: creator_id}),
    do: true

  defp visible_to?(%Task{status: "draft"}, _user), do: false
  defp visible_to?(%Task{}, _user), do: true

  defp scope_visibility(query, %User{}, "created"), do: query
  defp scope_visibility(query, _user, _mine), do: from(t in query, where: t.status != "draft")

  defp filter_status(query, status)
       when status in ~w(draft open in_progress under_review completed expired cancelled),
       do: from(t in query, where: t.status == ^status)

  defp filter_status(query, "closed"),
    do: from(t in query, where: t.status in ["expired", "cancelled"])

  defp filter_status(query, _), do: query

  defp filter_query(query, value) when is_binary(value) and value != "" do
    pattern = "%" <> escape_like(String.trim(value)) <> "%"
    from(t in query, where: ilike(t.title, ^pattern) or ilike(t.description, ^pattern))
  end

  defp filter_query(query, _), do: query

  defp filter_node(query, nil), do: query

  defp filter_node(query, id) do
    if Rice.Tsid.valid?(id),
      do: from(t in query, where: t.node_id == ^id),
      else: from(t in query, where: false)
  end

  defp filter_available(query, %User{id: id}, value) when value in [true, "true", "1"] do
    now = DateTime.utc_now()

    applied =
      from a in Application,
        where: a.task_id == parent_as(:task).id and a.user_id == ^id,
        select: 1

    from(t in query,
      where:
        t.status == "open" and t.creator_id != ^id and not exists(applied) and
          (is_nil(t.application_deadline) or t.application_deadline > ^now)
    )
  end

  defp filter_available(query, nil, value) when value in [true, "true", "1"],
    do: from(t in query, where: false)

  defp filter_available(query, _, _), do: query

  defp paginate_tasks(query, %{"sort" => "published"} = params) do
    %{limit: limit, before: before} = Pagination.params(params)

    published_events =
      from(e in Event,
        where:
          e.to_status == "open" and
            (is_nil(e.detail) or e.detail != "状态记录从这里开始"),
        group_by: e.task_id,
        select: %{task_id: e.task_id, cursor: min(e.id)}
      )

    query =
      from([task: task] in query,
        left_join: published in subquery(published_events),
        as: :published,
        on: published.task_id == task.id,
        select_merge: %{
          search_cursor: fragment("COALESCE(?, ?)", published.cursor, task.id)
        }
      )
      |> before_published(before)
      |> order_by(
        [task: task, published: published],
        desc: fragment("COALESCE(?, ?)", published.cursor, task.id)
      )
      |> limit(^(limit + 1))
      |> Repo.all()

    {entries, more} = Enum.split(query, limit)

    %{
      entries: entries,
      next_cursor: if(more == [], do: nil, else: List.last(entries).search_cursor)
    }
  end

  defp paginate_tasks(query, params),
    do: Pagination.paginate(query, Repo, Pagination.params(params))

  defp before_published(query, nil), do: query

  defp before_published(query, before) do
    from([task: task, published: published] in query,
      where: fragment("COALESCE(?, ?)", published.cursor, task.id) < ^before
    )
  end

  defp scope_public_user(query, participant_did, creator_did) do
    query
    |> scope_participant(participant_did)
    |> scope_creator(creator_did)
  end

  defp scope_participant(query, did) when is_binary(did) and did != "" do
    from(t in query, join: user in User, on: user.id == t.assignee_id, where: user.did == ^did)
  end

  defp scope_participant(query, _did), do: query

  defp scope_creator(query, did) when is_binary(did) and did != "" do
    from(t in query,
      join: creator in User,
      on: creator.id == t.creator_id,
      where: creator.did == ^did
    )
  end

  defp scope_creator(query, _did), do: query

  defp scope_mine(query, %User{id: id}, "created"),
    do: from(t in query, where: t.creator_id == ^id)

  defp scope_mine(query, %User{id: id}, "assigned"),
    do: from(t in query, where: t.assignee_id == ^id)

  defp scope_mine(query, %User{id: id}, "applied") do
    application =
      from(a in Application,
        where: a.task_id == parent_as(:task).id and a.user_id == ^id,
        select: 1
      )

    from(t in query,
      where: exists(application) and (is_nil(t.assignee_id) or t.assignee_id != ^id)
    )
  end

  defp scope_mine(query, nil, mine) when mine in ~w(created assigned applied),
    do: from(t in query, where: false)

  defp scope_mine(query, _user, _mine), do: query

  defp conditional_update(repo, query, updates) do
    case repo.update_all(query, set: updates) do
      {1, _} -> {:ok, :updated}
      _ -> {:error, :conflict}
    end
  end

  # Core terms and the reviewed submission must come from the same locked task state.
  defp with_locked_task(task_id, action) do
    Repo.transaction(fn ->
      case Repo.one(from t in Task, where: t.id == ^task_id, lock: "FOR UPDATE") do
        nil ->
          Repo.rollback(:not_found)

        task ->
          case action.(task) do
            {:ok, result} -> result
            {:error, reason} -> Repo.rollback(reason)
          end
      end
    end)
  end

  defp transition_task(query, task, updates, actor_id, detail, notifications) do
    transition_task(query, task, updates, actor_id, detail, notifications, nil)
  end

  defp transition_task(query, task, updates, actor_id, detail, notifications, reward_step) do
    now = DateTime.utc_now()

    multi =
      Multi.new()
      |> Multi.run(:task, fn repo, _ ->
        conditional_update(repo, query, Keyword.put(updates, :updated_at, now))
      end)
      |> maybe_run_reward(reward_step)
      |> Multi.insert(
        :event,
        event_changeset(task.id, actor_id, task.status, Keyword.fetch!(updates, :status), detail)
      )
      |> Multi.run(:notification_rows, fn repo, _ ->
        {:ok, notification_rows(notifications, repo)}
      end)

    multi
    |> Multi.merge(fn %{notification_rows: rows} -> notification_multi(task, rows) end)
    |> Repo.transaction()
    |> transaction_task(task.id)
  end

  defp maybe_run_reward(multi, nil), do: multi

  defp maybe_run_reward(multi, reward_step) do
    Multi.run(multi, :task_reward, reward_step)
  end

  defp reserve_reward(%Task{reward_amount: amount} = task) when amount > 0 do
    {
      [status: "open", reward_status: "reserved"],
      reward_detail(task, :reserved),
      fn repo, _changes ->
        Grains.reserve_business(repo, task.creator_id, amount, "rice://tasks/#{task.id}")
      end
    }
  end

  defp reserve_reward(_task), do: {[status: "open"], nil, nil}

  defp refund_reward(%Task{reward_status: "reserved", reward_amount: amount} = task, status)
       when amount > 0 do
    {
      [status: status, reward_status: "refunded"],
      reward_detail(task, :refunded),
      fn repo, _changes ->
        Grains.refund_business(repo, task.creator_id, amount, "rice://tasks/#{task.id}")
      end
    }
  end

  defp refund_reward(_task, status), do: {[status: status], nil, nil}

  defp settle_reward(
         %Task{reward_status: "reserved", reward_amount: amount} = task,
         assignee_id
       )
       when amount > 0 do
    {
      [status: "completed", reward_status: "settled"],
      reward_detail(task, :settled),
      fn repo, _changes ->
        Grains.settle_business(
          repo,
          task.creator_id,
          assignee_id,
          amount,
          "rice://tasks/#{task.id}"
        )
      end
    }
  end

  defp settle_reward(_task, _assignee_id), do: {[status: "completed"], nil, nil}

  defp reward_detail(%Task{reward_amount: amount}, action) when amount > 0 do
    case action do
      :reserved -> "已冻结 #{amount} 稻米作为任务奖励"
      :settled -> "已向承作人发放 #{amount} 稻米"
      :refunded -> "已向发布者退回 #{amount} 稻米"
    end
  end

  defp reward_detail(_task, _action), do: nil

  defp notification_rows(builder, repo) when is_function(builder, 1), do: builder.(repo)
  defp notification_rows(rows, _repo), do: rows

  defp notification_multi(task, rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce(Multi.new(), fn {{recipient_id, actor_id, event, detail}, index}, multi ->
      Multi.insert(
        multi,
        {:notification, index},
        notification_changeset(task, recipient_id, actor_id, event, detail)
      )
    end)
  end

  defp applicant_ids(repo, task_id) do
    repo.all(from(a in Application, where: a.task_id == ^task_id, select: a.user_id))
  end

  defp lock_open_task(repo, task_id, now) do
    query =
      from(t in Task,
        where:
          t.id == ^task_id and t.status == "open" and
            (is_nil(t.application_deadline) or t.application_deadline > ^now),
        lock: "FOR UPDATE"
      )

    case repo.one(query) do
      nil -> {:error, :conflict}
      task -> {:ok, task}
    end
  end

  defp notification_changeset(task, recipient_id, actor_id, event, detail \\ nil) do
    Notification.create_changeset(%Notification{}, %{
      task_id: task.id,
      recipient_id: recipient_id,
      actor_id: actor_id,
      event: event,
      detail: detail
    })
  end

  defp event_changeset(task_id, actor_id, from_status, to_status, detail \\ nil) do
    Event.create_changeset(%Event{}, %{
      task_id: task_id,
      actor_id: actor_id,
      from_status: from_status,
      to_status: to_status,
      detail: detail
    })
  end

  defp escape_like(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp fetch_record(schema, task_id, id) do
    if Rice.Tsid.valid?(id) do
      case Repo.get_by(schema, id: id, task_id: task_id) do
        nil -> {:error, :not_found}
        record -> {:ok, record}
      end
    else
      {:error, :not_found}
    end
  end

  defp transaction_task({:ok, _changes}, task_id), do: fetch_task_record(task_id)
  defp transaction_task({:error, _step, reason, _changes}, _task_id), do: {:error, reason}

  defp preload_list(tasks) do
    Repo.preload(tasks,
      image_links: :attachment,
      node: [:logo, user: :avatar],
      creator: :avatar,
      assignee: :avatar,
      applications: [],
      events: from(e in Event, where: e.to_status == "open", order_by: [asc: e.id])
    )
  end

  defp preload_detail(task) do
    Repo.preload(task,
      image_links: :attachment,
      node: [:logo, user: :avatar],
      creator: :avatar,
      assignee: :avatar,
      applications: [user: :avatar],
      submissions: [user: :avatar],
      events: from(e in Event, order_by: [asc: e.id], preload: [actor: :avatar])
    )
  end
end
