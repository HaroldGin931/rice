defmodule Rice.Tasks do
  @moduledoc """
  Task V1：草稿、发布、申请领取、任命、取消、失效、提交与审核。

  稻米奖励与节点稻米池尚无已确认结算 API，因此不进入本状态机。
  """
  import Ecto.Query

  alias Ecto.Multi
  alias Rice.Accounts.User
  alias Rice.Tasks.{Application, Event, Notification, Submission, Task}
  alias Rice.{Pagination, Repo}

  def list_tasks(user, params \\ %{}) do
    expire_due_tasks()

    page =
      from(t in Task, as: :task)
      |> scope_visibility(user, params["mine"])
      |> filter_status(params["status"])
      |> filter_query(params["q"])
      |> scope_public_user(params["participant_did"], params["creator_did"])
      |> scope_mine(user, params["mine"])
      |> Pagination.paginate(Repo, Pagination.params(params))

    %{page | entries: preload_list(page.entries)}
  end

  def fetch_task(id, user \\ nil) do
    expire_due_task(id)

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

  def create_task(%User{can_publish_tasks: true} = user, attrs) do
    with {:ok, status} <- initial_status(attrs) do
      task_changeset =
        %Task{creator_id: user.id, status: status}
        |> Task.create_changeset(attrs)

      Multi.new()
      |> Multi.insert(:task, task_changeset)
      |> Multi.insert(:event, fn %{task: task} ->
        event_changeset(task.id, user.id, nil, status)
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{task: task}} -> {:ok, preload_detail(task)}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    end
  end

  def create_task(%User{}, _attrs), do: {:error, :forbidden}

  def update_draft(
        %User{id: creator_id},
        %Task{creator_id: creator_id, status: "draft"} = task,
        attrs
      ) do
    changeset = Task.create_changeset(task, attrs)

    if changeset.valid? do
      update_task(
        from(t in Task, where: t.id == ^task.id and t.status == "draft"),
        task.id,
        title: Ecto.Changeset.get_field(changeset, :title),
        description: Ecto.Changeset.get_field(changeset, :description),
        application_deadline: Ecto.Changeset.get_field(changeset, :application_deadline)
      )
    else
      {:error, changeset}
    end
  end

  def update_draft(%User{id: creator_id}, %Task{creator_id: creator_id}, _attrs),
    do: {:error, :conflict}

  def update_draft(%User{}, %Task{}, _attrs), do: {:error, :forbidden}

  def publish_draft(
        %User{id: creator_id},
        %Task{creator_id: creator_id, status: "draft"} = task
      ) do
    case Task.publish_changeset(task) do
      %{valid?: true} ->
        transition_task(
          from(t in Task, where: t.id == ^task.id and t.status == "draft"),
          task,
          [status: "open"],
          creator_id
        )

      changeset ->
        {:error, changeset}
    end
  end

  def publish_draft(%User{id: creator_id}, %Task{creator_id: creator_id}),
    do: {:error, :conflict}

  def publish_draft(%User{}, %Task{}), do: {:error, :forbidden}

  def cancel(%User{id: creator_id}, %Task{creator_id: creator_id, status: "open"} = task) do
    notifications =
      fn repo ->
        Enum.map(applicant_ids(repo, task.id), &{&1, creator_id, "task_cancelled", nil})
      end

    transition_task(
      from(t in Task, where: t.id == ^task.id and t.status == "open"),
      task,
      [status: "cancelled"],
      creator_id,
      nil,
      notifications
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
    |> Multi.insert(:application, application)
    |> Multi.insert(
      :notification,
      fn %{task: current_task} ->
        notification_changeset(
          current_task,
          current_task.creator_id,
          user.id,
          "application_created"
        )
      end
    )
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
    with {:ok, application} <- fetch_record(Application, task.id, application_id) do
      appoint_application(user, task, application, attrs)
    end
  end

  defp appoint_application(
         %User{id: creator_id},
         %Task{creator_id: creator_id, status: "open"} = task,
         %Application{task_id: task_id} = application,
         attrs
       )
       when task_id == task.id do
    changeset = Task.appointment_changeset(task, attrs)

    if changeset.valid? do
      appointment_reason = Ecto.Changeset.get_field(changeset, :appointment_reason)

      notifications =
        fn repo ->
          Enum.map(applicant_ids(repo, task.id), fn user_id ->
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
    with {:ok, submission} <- fetch_record(Submission, task.id, submission_id) do
      approve_submission(user, task, submission)
    end
  end

  defp approve_submission(
         %User{id: creator_id},
         %Task{creator_id: creator_id, status: "under_review"} = task,
         %Submission{task_id: task_id, review_reason: nil} = submission
       )
       when task_id == task.id do
    transition_task(
      from(t in Task, where: t.id == ^task.id and t.status == "under_review"),
      task,
      [status: "completed"],
      creator_id,
      nil,
      [{submission.user_id, creator_id, "result_approved", nil}]
    )
  end

  defp approve_submission(%User{id: creator_id}, %Task{creator_id: creator_id}, %Submission{}),
    do: {:error, :conflict}

  defp approve_submission(%User{}, %Task{}, %Submission{}), do: {:error, :forbidden}

  def request_changes(user, %Task{} = task, submission_id, reason) do
    with {:ok, submission} <- fetch_record(Submission, task.id, submission_id) do
      request_submission_changes(user, task, submission, reason)
    end
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

  def expire_due_tasks(now \\ DateTime.utc_now()) do
    expired =
      from(t in Task,
        where:
          t.status == "open" and not is_nil(t.application_deadline) and
            t.application_deadline <= ^now
      )
      |> expire_tasks(now)

    %{expired: expired}
  end

  def list_notifications(%User{id: user_id}) do
    from(n in Notification,
      where: n.recipient_id == ^user_id,
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

  defp scope_public_user(query, participant_did, creator_did) do
    query
    |> scope_participant(participant_did)
    |> scope_creator(creator_did)
  end

  defp scope_participant(query, did) when is_binary(did) and did != "" do
    application =
      from(a in Application,
        join: user in User,
        on: user.id == a.user_id,
        where: a.task_id == parent_as(:task).id and user.did == ^did,
        select: 1
      )

    from(t in query, where: exists(application))
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

  defp expire_due_task(id) do
    if Rice.Tsid.valid?(id) do
      now = DateTime.utc_now()

      from(t in Task,
        where:
          t.id == ^id and t.status == "open" and not is_nil(t.application_deadline) and
            t.application_deadline <= ^now
      )
      |> expire_tasks(now)
    end
  end

  defp expire_tasks(query, now) do
    {:ok, expired} =
      Repo.transaction(fn ->
        {count, tasks} =
          query
          |> select([t], {t.id, t.creator_id})
          |> Repo.update_all(set: [status: "expired", updated_at: now])

        creators = Map.new(tasks)
        task_ids = Map.keys(creators)

        Enum.each(tasks, fn {task_id, _creator_id} ->
          event_changeset(task_id, nil, "open", "expired") |> Repo.insert!()
        end)

        if task_ids != [] do
          from(a in Application,
            where: a.task_id in ^task_ids,
            select: {a.task_id, a.user_id}
          )
          |> Repo.all()
          |> Enum.each(fn {task_id, recipient_id} ->
            task = %Task{id: task_id}

            notification_changeset(
              task,
              recipient_id,
              Map.fetch!(creators, task_id),
              "task_expired"
            )
            |> Repo.insert!()
          end)
        end

        count
      end)

    expired
  end

  defp conditional_update(repo, query, updates) do
    case repo.update_all(query, set: updates) do
      {1, _} -> {:ok, :updated}
      _ -> {:error, :conflict}
    end
  end

  defp update_task(query, task_id, updates) do
    case conditional_update(
           Repo,
           query,
           Keyword.put(updates, :updated_at, DateTime.utc_now())
         ) do
      {:ok, _} -> fetch_task_record(task_id)
      error -> error
    end
  end

  defp transition_task(query, task, updates, actor_id, detail \\ nil, notifications \\ []) do
    now = DateTime.utc_now()

    multi =
      Multi.new()
      |> Multi.run(:task, fn repo, _ ->
        conditional_update(repo, query, Keyword.put(updates, :updated_at, now))
      end)
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
    Repo.preload(tasks, creator: :avatar, assignee: :avatar, applications: [])
  end

  defp preload_detail(task) do
    Repo.preload(task,
      creator: :avatar,
      assignee: :avatar,
      applications: [user: :avatar],
      submissions: [user: :avatar],
      events: from(e in Event, order_by: [asc: e.id], preload: [actor: :avatar])
    )
  end
end
