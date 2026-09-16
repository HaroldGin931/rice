defmodule Rice.Inbox do
  @moduledoc "Task, activity and membership messages share the existing private inbox."
  import Ecto.Query
  alias Rice.{Repo, Tasks.Notification}

  def notify(repo, recipient_id, actor_id, event, detail, type, id) do
    %Notification{}
    |> Notification.create_changeset(%{
      recipient_id: recipient_id,
      actor_id: actor_id,
      event: event,
      detail: detail,
      subject_type: type,
      subject_id: id
    })
    |> repo.insert()
  end

  def list(user) do
    Repo.all(
      from n in Notification,
        where: n.recipient_id == ^user.id,
        order_by: [desc: n.id],
        limit: 100,
        preload: [actor: :avatar, task: []]
    )
    |> Enum.map(fn n ->
      type = n.subject_type || "task"
      title = if n.task, do: n.task.title, else: nil

      %{
        uri: "business-notification:#{n.id}",
        reason: "task-#{n.event}",
        record: %{text: Enum.join(Enum.reject([title, n.detail], &is_nil/1), " · ")},
        isRead: not is_nil(n.read_at),
        indexedAt: n.inserted_at,
        author: %{handle: n.actor.handle, displayName: n.actor.nickname},
        taskId: n.task_id,
        subjectType: type,
        subjectId: n.subject_id || n.task_id
      }
    end)
  end

  def mark_read(user), do: Rice.Tasks.mark_notifications_read(user)
end
