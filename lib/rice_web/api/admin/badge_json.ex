defmodule RiceWeb.Api.Admin.BadgeJSON do
  alias RiceWeb.Api.{AttachmentJSON, UserJSON}

  def index(%{page: page}) do
    %{data: Enum.map(page.entries, &data/1), meta: Rice.Pagination.meta(page)}
  end

  def show(%{badge: badge}), do: %{data: data(badge)}

  def holders(%{page: page}) do
    %{data: Enum.map(page.entries, &holder/1), meta: Rice.Pagination.meta(page)}
  end

  defp data(badge) do
    %{
      id: badge.id,
      name: badge.name,
      image: AttachmentJSON.embed(badge.image),
      # core 把持有人数缓存在 t_medal.quantity 上,这里现算
      holder_count: Map.get(badge, :holder_count),
      inserted_at: badge.inserted_at
    }
  end

  defp holder(award) do
    award.user
    |> UserJSON.public()
    |> Map.merge(%{
      email: award.user.email,
      phone: award.user.phone,
      awarded_at: award.awarded_at
    })
  end
end
