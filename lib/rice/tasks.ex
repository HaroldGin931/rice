defmodule Rice.Tasks do
  @moduledoc """
  Task V1：发布、申请领取、任命、提交结果、审核通过或驳回并留言。

  稻米奖励与节点稻米池尚无已确认结算 API，因此不进入本状态机。
  """
  import Ecto.Query

  alias Ecto.Multi
  alias Rice.Accounts.User
  alias Rice.Tasks.{Application, Submission, Task}
  alias Rice.{Pagination, Repo}

  def list_tasks(user, params \\ %{}) do
    page =
      from(t in Task, as: :task)
      |> filter_status(params["status"])
      |> scope_mine(user, params["mine"])
      |> Pagination.paginate(Repo, Pagination.params(params))

    %{page | entries: preload_list(page.entries)}
  end

  def fetch_task(id) do
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
    %Task{creator_id: user.id}
    |> Task.create_changeset(attrs)
    |> Repo.insert()
    |> with_detail()
  end

  def create_task(%User{}, _attrs), do: {:error, :forbidden}

  def apply(%User{id: user_id}, %Task{creator_id: user_id}, _attrs),
    do: {:error, :forbidden}

  def apply(%User{} = user, %Task{status: "open"} = task, attrs) do
    %Application{task_id: task.id, user_id: user.id}
    |> Application.create_changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, application} -> {:ok, Repo.preload(application, user: :avatar)}
      error -> error
    end
  end

  def apply(%User{}, %Task{}, _attrs), do: {:error, :conflict}

  def appoint(user, %Task{} = task, application_id) do
    with {:ok, application} <- fetch_record(Application, task.id, application_id) do
      appoint_application(user, task, application)
    end
  end

  defp appoint_application(
         %User{id: creator_id},
         %Task{creator_id: creator_id, status: "open"} = task,
         %Application{task_id: task_id} = application
       )
       when task_id == task.id do
    update_task(
      from(t in Task, where: t.id == ^task.id and t.status == "open"),
      task.id,
      status: "in_progress",
      assignee_id: application.user_id
    )
  end

  defp appoint_application(%User{id: creator_id}, %Task{creator_id: creator_id}, %Application{}),
    do: {:error, :conflict}

  defp appoint_application(%User{}, %Task{}, %Application{}), do: {:error, :forbidden}

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
    |> Multi.insert(:submission, changeset)
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
         %Submission{task_id: task_id, review_reason: nil}
       )
       when task_id == task.id do
    update_task(
      from(t in Task, where: t.id == ^task.id and t.status == "under_review"),
      task.id,
      status: "completed"
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
      |> Multi.update(:submission, changeset)
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

  defp filter_status(query, status) when status in ~w(open in_progress under_review completed),
    do: from(t in query, where: t.status == ^status)

  defp filter_status(query, _), do: query

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

    from(t in query, where: t.status == "open" and exists(application))
  end

  defp scope_mine(query, _user, _mine), do: query

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
      {:ok, _} -> fetch_task(task_id)
      error -> error
    end
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

  defp transaction_task({:ok, _changes}, task_id), do: fetch_task(task_id)
  defp transaction_task({:error, _step, reason, _changes}, _task_id), do: {:error, reason}

  defp with_detail({:ok, task}), do: {:ok, preload_detail(task)}
  defp with_detail(error), do: error

  defp preload_list(tasks) do
    Repo.preload(tasks, creator: :avatar, assignee: :avatar, applications: [])
  end

  defp preload_detail(task) do
    Repo.preload(task,
      creator: :avatar,
      assignee: :avatar,
      applications: [user: :avatar],
      submissions: [user: :avatar]
    )
  end
end
