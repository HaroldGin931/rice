defmodule Rice.Tasks.Notification do
  @moduledoc "任务状态变化发给相关用户的站内通知。"
  use Rice.Schema

  @events ~w(application_created assignee_appointed application_not_selected task_cancelled result_submitted result_approved changes_requested)

  schema "task_notifications" do
    field(:event, :string)
    field(:detail, :string)
    field(:read_at, :utc_datetime_usec)

    belongs_to(:task, Rice.Tasks.Task)
    belongs_to(:recipient, Rice.Accounts.User)
    belongs_to(:actor, Rice.Accounts.User)

    timestamps()
  end

  def create_changeset(notification, attrs) do
    notification
    |> cast(attrs, [:task_id, :recipient_id, :actor_id, :event, :detail])
    |> validate_required([:task_id, :recipient_id, :actor_id, :event])
    |> validate_inclusion(:event, @events)
    |> update_change(:detail, &optional_trim/1)
    |> validate_length(:detail, max: 512)
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:recipient_id)
    |> foreign_key_constraint(:actor_id)
  end

  defp optional_trim(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp optional_trim(_), do: nil
end
