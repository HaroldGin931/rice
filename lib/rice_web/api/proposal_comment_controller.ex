defmodule RiceWeb.Api.ProposalCommentController do
  @moduledoc "提案评论。替代 core 的 /proposal/comment 和 /proposal/delete-my-comment。"
  use RiceWeb, :controller

  alias Rice.Governance

  action_fallback RiceWeb.Api.FallbackController

  def index(conn, %{"proposal_id" => proposal_id} = params) do
    with {:ok, proposal} <- Governance.fetch_proposal(proposal_id) do
      render(conn, :index, page: Governance.list_comments(proposal, params))
    end
  end

  def create(conn, %{"proposal_id" => proposal_id} = params) do
    with {:ok, proposal} <- Governance.fetch_proposal(proposal_id),
         {:ok, comment} <-
           Governance.create_comment(conn.assigns.current_user, proposal, params["body"] || "") do
      conn |> put_status(:created) |> render(:show, comment: comment)
    end
  end

  def delete(conn, %{"proposal_id" => proposal_id, "id" => id}) do
    with {:ok, proposal} <- Governance.fetch_proposal(proposal_id),
         {:ok, comment} <- Governance.fetch_comment(proposal, id),
         {:ok, _} <- Governance.delete_comment(conn.assigns.current_user, comment) do
      send_resp(conn, :no_content, "")
    end
  end
end
