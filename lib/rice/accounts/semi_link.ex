defmodule Rice.Accounts.SemiLink do
  @moduledoc "Maps a Semi subject (`sub`) to the AT Protocol account rice owns for it."
  use Ecto.Schema
  import Ecto.Changeset

  schema "semi_links" do
    field :semi_sub, :string
    field :did, :string
    field :handle, :string
    field :account_password_ciphertext, :binary

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:semi_sub, :did, :handle, :account_password_ciphertext])
    |> validate_required([:semi_sub, :did, :handle, :account_password_ciphertext])
    |> unique_constraint(:semi_sub)
    |> unique_constraint(:did)
  end
end
