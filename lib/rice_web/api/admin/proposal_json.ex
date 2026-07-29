defmodule RiceWeb.Api.Admin.ProposalJSON do
  alias RiceWeb.Api.{AttachmentJSON, ProposalCommentJSON, UserJSON}

  def index(%{page: page}) do
    %{data: Enum.map(page.entries, &data/1), meta: Rice.Pagination.meta(page)}
  end

  def show(%{proposal: proposal, comments: comments}) do
    %{
      data:
        Map.put(
          data(proposal),
          :comments,
          Enum.map(comments.entries, &ProposalCommentJSON.data/1)
        )
    }
  end

  defp data(proposal) do
    %{
      id: proposal.id,
      title: proposal.title,
      status: proposal.status,
      # C 端列表看不到下架的,后台要看得到才能复核
      listed: proposal.listed,
      closes_at: proposal.closes_at,
      agree_count: proposal.agree_count,
      oppose_count: proposal.oppose_count,
      total_votes: proposal.agree_count + proposal.oppose_count,
      attachment: AttachmentJSON.embed(proposal.attachment),
      author: author(proposal.user),
      deleted_at: proposal.deleted_at,
      inserted_at: proposal.inserted_at
    }
  end

  defp author(%Ecto.Association.NotLoaded{}), do: nil
  defp author(nil), do: nil
  defp author(user), do: UserJSON.public(user)
end
