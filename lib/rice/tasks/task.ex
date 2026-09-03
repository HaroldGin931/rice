defmodule Rice.Tasks.Task do
  @moduledoc "任务主体；奖励由发布者余额冻结，并在结果认可后发放。"
  use Rice.Schema

  @statuses ~w(draft open in_progress under_review completed expired cancelled)

  schema "tasks" do
    field(:title, :string)
    field(:description, :string)
    field(:status, :string, default: "open")
    field(:application_deadline, :utc_datetime_usec)
    field(:appointed_at, :utc_datetime_usec)
    field(:appointment_reason, :string)
    field(:reward_amount, :integer, default: 0)
    field(:reward_status, :string, default: "none")
    field(:search_cursor, :string, virtual: true)

    belongs_to(:creator, Rice.Accounts.User)
    belongs_to(:assignee, Rice.Accounts.User)
    has_many(:applications, Rice.Tasks.Application)
    has_many(:submissions, Rice.Tasks.Submission)
    has_many(:events, Rice.Tasks.Event)

    timestamps()
  end

  @doc "发布者只能提交任务内容；身份与状态由服务端填写。"
  def create_changeset(task, attrs) do
    task
    |> cast(attrs, [:title, :description, :application_deadline, :reward_amount])
    |> validate_required([:title, :description])
    |> update_change(:title, &trim/1)
    |> update_change(:description, &trim/1)
    |> validate_length(:title, min: 1, max: 128)
    |> validate_length(:description, min: 1, max: 4000)
    |> validate_number(:reward_amount, greater_than_or_equal_to: 0)
    |> validate_future_deadline()
    |> unique_constraint(:creator_id, name: :tasks_one_draft_per_creator)
  end

  def appointment_changeset(task, attrs) do
    task
    |> cast(attrs, [:appointment_reason])
    |> update_change(:appointment_reason, &optional_trim/1)
    |> validate_length(:appointment_reason, max: 512)
  end

  def publish_changeset(task) do
    task
    |> change()
    |> validate_future_deadline()
  end

  def statuses, do: @statuses

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_), do: ""

  defp optional_trim(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp optional_trim(_), do: nil

  defp validate_future_deadline(changeset) do
    case get_field(changeset, :application_deadline) do
      nil ->
        changeset

      deadline ->
        if DateTime.compare(deadline, DateTime.utc_now()) == :gt,
          do: changeset,
          else: add_error(changeset, :application_deadline, "领取截止时间必须在将来")
    end
  end
end
