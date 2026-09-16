defmodule Rice.Community.Membership do
  @moduledoc "社区正式成员；唯一管理员直接由 nodes.user_id 表示。"
  use Rice.Schema

  schema "node_memberships" do
    belongs_to :node, Rice.Community.Node
    belongs_to :user, Rice.Accounts.User
    timestamps()
  end

  def changeset(membership) do
    membership
    |> change()
    |> validate_required([:node_id, :user_id])
    |> unique_constraint([:node_id, :user_id])
    |> foreign_key_constraint(:node_id)
    |> foreign_key_constraint(:user_id)
  end
end
