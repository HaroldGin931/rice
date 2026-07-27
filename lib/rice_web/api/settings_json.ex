defmodule RiceWeb.Api.SettingsJSON do
  alias RiceWeb.Api.AttachmentJSON

  def foundation(%{site: site}) do
    %{
      data: %{
        fund_scale: site.fund_scale,
        issued_grain_scale: site.issued_grain_scale,
        proposal_approval_votes: site.proposal_approval_votes,
        documents: documents(site.documents)
      }
    }
  end

  defp documents(%Ecto.Association.NotLoaded{}), do: []

  defp documents(documents),
    do: Enum.map(documents, &AttachmentJSON.embed(&1.attachment))
end
