defmodule RiceWeb.Api.ProposalController do
  @moduledoc "提案。替代 core 的 /proposal/* 一组接口。"
  use RiceWeb, :controller

  alias Rice.Governance

  action_fallback RiceWeb.Api.FallbackController

  def index(conn, params) do
    page =
      if params["mine"] in ~w(1 true created voted all) and conn.assigns[:current_user] do
        Governance.list_my_proposals(conn.assigns.current_user, params)
      else
        Governance.list_proposals(params)
      end

    render(conn, :index,
      page: page,
      my_votes: Governance.my_votes(conn.assigns[:current_user], page.entries)
    )
  end

  def show(conn, %{"id" => id}) do
    with {:ok, proposal} <- Governance.fetch_proposal(id) do
      render(conn, :show,
        proposal: proposal,
        my_votes: Governance.my_votes(conn.assigns[:current_user], [proposal])
      )
    end
  end

  def create(conn, params) do
    with {:ok, proposal} <- Governance.create_proposal(conn.assigns.current_user, params) do
      conn |> put_status(:created) |> render(:show, proposal: proposal)
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, proposal} <- Governance.fetch_proposal(id),
         {:ok, _} <- Governance.delete_proposal(conn.assigns.current_user, proposal) do
      send_resp(conn, :no_content, "")
    end
  end
end
