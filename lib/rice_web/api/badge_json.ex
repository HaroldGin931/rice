defmodule RiceWeb.Api.BadgeJSON do
  alias RiceWeb.Api.AttachmentJSON

  def index(%{badges: badges}) do
    %{data: Enum.map(badges, fn {badge, awarded_at} -> data(badge, awarded_at) end)}
  end

  defp data(badge, awarded_at) do
    %{
      id: badge.id,
      name: badge.name,
      image: AttachmentJSON.embed(badge.image),
      # 这个人拿到这枚勋章的时间;没拿到是 null。
      awarded_at: awarded_at
    }
  end
end
