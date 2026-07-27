defmodule RiceWeb.Api.Admin.TemplateJSON do
  alias RiceWeb.Api.AttachmentJSON

  def index(%{grain_distribution: grain, badge_distribution: badge}) do
    %{
      data: %{
        grain_distribution: AttachmentJSON.embed(grain),
        badge_distribution: AttachmentJSON.embed(badge)
      }
    }
  end
end
