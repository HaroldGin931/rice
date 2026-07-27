defmodule RiceWeb.Api.Admin.SettingsJSON do
  alias RiceWeb.Api.AttachmentJSON

  def show(%{site: site}) do
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
  defp documents(nil), do: []

  defp documents(docs),
    do:
      docs
      |> Enum.map(& &1.attachment)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&AttachmentJSON.embed/1)
end
