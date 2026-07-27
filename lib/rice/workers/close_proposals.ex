defmodule Rice.Workers.CloseProposals do
  @moduledoc """
  每分钟把到期的提案结掉。

  对应 core 的 `ProposalEndJob`(Hangfire,任务状态存 Redis —— 生产 Redis 里
  99% 的 key 都是它留下的)。Oban 把任务表放在业务库里,顺带把 Redis 这个依赖也省了。
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  @impl true
  def perform(_job) do
    result = Rice.Governance.close_due_proposals()

    if result.passed > 0 or result.rejected > 0 do
      Logger.info("结票:通过 #{result.passed},未通过 #{result.rejected}")
    end

    :ok
  end
end
