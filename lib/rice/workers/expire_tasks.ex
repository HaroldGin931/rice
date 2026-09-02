defmodule Rice.Workers.ExpireTasks do
  @moduledoc "每分钟把超过领取截止时间且仍未任命的任务标记为失效。"
  use Oban.Worker, queue: :default, max_attempts: 3

  @impl true
  def perform(_job) do
    Rice.Tasks.expire_due_tasks()
    :ok
  end
end
