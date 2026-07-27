defmodule RiceWeb.Api.UserJSON do
  alias RiceWeb.Api.AttachmentJSON

  def show(%{user: user}), do: %{data: data(user)}

  @doc "自己看自己 —— 含手机、邮箱这类私有字段。"
  def data(user) do
    %{
      id: user.id,
      did: user.did,
      handle: user.handle,
      nickname: user.nickname,
      bio: user.bio,
      avatar: AttachmentJSON.embed(user.avatar),
      grain_balance: user.grain_balance,
      node_member: user.node_member,
      email: user.email,
      phone: user.phone,
      phone_region: user.phone_region,
      inserted_at: user.inserted_at
    }
  end

  @doc "别人看你 —— 联系方式不外露。"
  def public(user) do
    %{
      id: user.id,
      did: user.did,
      handle: user.handle,
      nickname: user.nickname,
      bio: user.bio,
      avatar: AttachmentJSON.embed(user.avatar),
      node_member: user.node_member
    }
  end
end
