defmodule Rice.Workers.ExpireTasks do
  @moduledoc "记录申请截止和执行逾期，保留候选与冻结报酬。"
  use Oban.Worker, queue: :default, max_attempts: 3

  @impl true
  def perform(_job) do
    Rice.Tasks.check_due_tasks()
    :ok
  end
end
