defmodule Rice.Tasks.Application do
  @moduledoc "用户对任务的申请；发布者任命一人后，其余申请标记为未入选。"
  use Rice.Schema

  schema "task_applications" do
    field(:reason, :string, default: "")

    belongs_to(:task, Rice.Tasks.Task)
    belongs_to(:user, Rice.Accounts.User)

    timestamps()
  end

  def create_changeset(application, attrs) do
    application
    |> cast(attrs, [:reason])
    |> update_change(:reason, &trim/1)
    |> validate_length(:reason, max: 512)
    |> unique_constraint([:task_id, :user_id])
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_), do: ""
end
