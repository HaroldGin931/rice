defmodule RiceWeb.Api.TaskJSON do
  @moduledoc "Task V1 的 JSON 表示。"
  alias Rice.Accounts.User
  alias Rice.Tasks.{Application, Submission}
  alias RiceWeb.Api.UserJSON

  def index(%{page: page} = assigns) do
    %{
      data: Enum.map(page.entries, &data(&1, assigns[:current_user], false)),
      meta: Rice.Pagination.meta(page)
    }
  end

  def show(%{task: task} = assigns),
    do: %{data: data(task, assigns[:current_user], true)}

  defp data(task, current_user, detail?) do
    applications = loaded(task.applications)
    submissions = loaded(task.submissions)

    %{
      id: task.id,
      title: task.title,
      description: task.description,
      status: task.status,
      creator: public_user(task.creator),
      assignee: public_user(task.assignee),
      application_count: length(applications),
      my_application_status: my_application_status(task, applications, current_user),
      allowed_actions: allowed_actions(task, applications, current_user),
      applications: visible_applications(task, applications, current_user, detail?),
      submissions: visible_submissions(task, submissions, current_user, detail?),
      inserted_at: task.inserted_at,
      updated_at: task.updated_at
    }
  end

  defp visible_applications(
         %{creator_id: user_id} = task,
         applications,
         %User{id: user_id},
         true
       ),
       do: Enum.map(applications, &application(&1, task))

  defp visible_applications(_task, _applications, _user, _detail?), do: nil

  defp visible_submissions(task, submissions, %User{id: user_id}, true)
       when user_id in [task.creator_id, task.assignee_id],
       do: Enum.map(submissions, &submission(&1, task))

  defp visible_submissions(_task, _submissions, _user, _detail?), do: nil

  defp application(%Application{} = application, task) do
    %{
      id: application.id,
      reason: application.reason,
      status: application_status(application, task),
      user: public_user(application.user),
      inserted_at: application.inserted_at
    }
  end

  defp submission(%Submission{} = submission, task) do
    %{
      id: submission.id,
      body: submission.body,
      status: submission_status(submission, task),
      review_reason: submission.review_reason,
      user: public_user(submission.user),
      inserted_at: submission.inserted_at
    }
  end

  defp allowed_actions(_task, _applications, nil), do: []

  defp allowed_actions(task, applications, %User{id: user_id}) do
    []
    |> maybe_add(
      task.status == "open" and task.creator_id != user_id and
        not Enum.any?(applications, &(&1.user_id == user_id)),
      "apply"
    )
    |> maybe_add(
      task.status == "open" and task.creator_id == user_id and
        applications != [],
      "appoint"
    )
    |> maybe_add(task.status == "in_progress" and task.assignee_id == user_id, "submit_result")
    |> maybe_add(task.status == "under_review" and task.creator_id == user_id, "approve_result")
    |> maybe_add(task.status == "under_review" and task.creator_id == user_id, "request_changes")
    |> Enum.reverse()
  end

  defp maybe_add(actions, true, action), do: [action | actions]
  defp maybe_add(actions, false, _action), do: actions

  defp my_application_status(_task, _applications, nil), do: nil

  defp my_application_status(task, applications, %User{id: user_id}) do
    case Enum.find(applications, &(&1.user_id == user_id)) do
      nil -> nil
      application -> application_status(application, task)
    end
  end

  defp application_status(%Application{user_id: id}, %{assignee_id: id}), do: "appointed"
  defp application_status(_application, %{status: "open"}), do: "pending"
  defp application_status(_application, _task), do: "not_selected"

  defp submission_status(%Submission{review_reason: reason}, _task) when not is_nil(reason),
    do: "changes_requested"

  defp submission_status(_submission, %{status: "completed"}), do: "approved"
  defp submission_status(_submission, _task), do: "pending"

  defp loaded(%Ecto.Association.NotLoaded{}), do: []
  defp loaded(items) when is_list(items), do: items

  defp public_user(nil), do: nil
  defp public_user(%Ecto.Association.NotLoaded{}), do: nil
  defp public_user(user), do: UserJSON.public(user)
end
