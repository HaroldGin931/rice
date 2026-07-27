defmodule RiceWeb.Api.NodeJSON do
  alias RiceWeb.Api.{AttachmentJSON, UserJSON}

  def index(%{nodes: nodes}), do: %{data: Enum.map(nodes, &data/1)}

  def members(%{users: users}), do: %{data: Enum.map(users, &UserJSON.public/1)}

  defp data(node) do
    %{
      id: node.id,
      name: node.name,
      description: node.description,
      position: node.position,
      logo: AttachmentJSON.embed(node.logo),
      # core 的 NodeListVo 把节点主的 did 和稻米数摊平在顶层;这里作为嵌套对象,
      # 昵称/头像也就跟着一起来了,不必再单独存一份副本。
      owner: owner(node.user)
    }
  end

  defp owner(%Ecto.Association.NotLoaded{}), do: nil
  defp owner(nil), do: nil

  defp owner(user) do
    user |> UserJSON.public() |> Map.put(:grain_balance, user.grain_balance)
  end
end
