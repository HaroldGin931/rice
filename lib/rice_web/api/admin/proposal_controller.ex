defmodule RiceWeb.Api.Admin.ProposalController do
  @moduledoc """
  提案的后台审核。列表能看到**已下架**的 —— C 端那份看不到,
  下架之后后台自己也找不回来就没法复核了。
  """
  use RiceWeb, :controller

  alias Rice.Governance

  action_fallback RiceWeb.Api.FallbackController

  def index(conn, params), do: render(conn, :index, page: Governance.list_all_proposals(params))

  def show(conn, %{"id" => id}) do
    with {:ok, proposal} <- Governance.fetch_any_proposal(id) do
      render(conn, :show,
        proposal: proposal,
        comments: Governance.list_comments(proposal, %{"limit" => "100"})
      )
    end
  end

  @doc "下架 / 恢复。core 的 take-off 只能单向下架,没有恢复的入口。"
  def update(conn, %{"id" => id} = params) do
    with {:ok, proposal} <- Governance.fetch_any_proposal(id),
         {:ok, proposal} <- Governance.set_listed(proposal, params["listed"]) do
      render(conn, :show, proposal: proposal, comments: %{entries: [], next_cursor: nil})
    end
  end

  @doc "删任意评论。C 端只能删自己的。"
  def delete_comment(conn, %{"proposal_id" => proposal_id, "id" => id}) do
    with {:ok, proposal} <- Governance.fetch_any_proposal(proposal_id),
         {:ok, _} <- Governance.admin_delete_comment(proposal, id) do
      send_resp(conn, :no_content, "")
    end
  end
end
