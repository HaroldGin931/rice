defmodule Rice.Community.Badge do
  @moduledoc "勋章(原 t_medal)。删掉了 quantity —— 那是 count(*) 的缓存。"
  use Rice.Schema

  schema "badges" do
    field :legacy_id, :string
    field :name, :string

    belongs_to :image, Rice.Files.Attachment
    has_many :awards, Rice.Community.BadgeAward

    timestamps()
  end

  def changeset(badge, attrs) do
    badge
    |> cast(attrs, [:legacy_id, :name, :image_id])
    |> validate_required([:name])
    |> validate_length(:name, max: 64)
    |> foreign_key_constraint(:image_id)
    |> unique_constraint(:legacy_id)
  end
end
