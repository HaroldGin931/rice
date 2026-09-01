defmodule Rice.Tasks.Task do
  @moduledoc "Task V1 的任务主体。奖励与结算不在这一版状态机里。"
  use Rice.Schema

  schema "tasks" do
    field(:title, :string)
    field(:description, :string)
    field(:status, :string, default: "open")

    belongs_to(:creator, Rice.Accounts.User)
    belongs_to(:assignee, Rice.Accounts.User)
    has_many(:applications, Rice.Tasks.Application)
    has_many(:submissions, Rice.Tasks.Submission)

    timestamps()
  end

  @doc "发布者只能提交标题和说明；身份与状态由服务端填写。"
  def create_changeset(task, attrs) do
    task
    |> cast(attrs, [:title, :description])
    |> validate_required([:title, :description])
    |> update_change(:title, &trim/1)
    |> update_change(:description, &trim/1)
    |> validate_length(:title, min: 1, max: 128)
    |> validate_length(:description, min: 1, max: 4000)
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_), do: ""
end
