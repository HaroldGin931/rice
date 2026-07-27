defmodule Rice.Grains.Transfer do
  @moduledoc """
  一笔稻米流转(合并了 core 的 t_point_record 与 t_point_distribute_record)。

  `kind`:
    * `reward` 打赏 —— 对着某条帖子
    * `gift`   赠送 —— 点对点
    * `grant`  后台发放 —— 增发,`from_user_id` 为 NULL
  """
  use Rice.Schema

  @kinds ~w(reward gift grant)

  schema "grain_transfers" do
    field :legacy_id, :string
    field :kind, :string
    field :amount, :integer
    field :memo, :string, default: ""
    field :subject_uri, :string

    belongs_to :from_user, Rice.Accounts.User
    belongs_to :to_user, Rice.Accounts.User

    timestamps()
  end

  def changeset(transfer, attrs) do
    transfer
    |> cast(attrs, [:kind, :from_user_id, :to_user_id, :amount, :memo, :subject_uri, :legacy_id])
    |> validate_required([:kind, :to_user_id, :amount])
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:amount, greater_than: 0)
    |> validate_length(:memo, max: 256)
    |> validate_length(:subject_uri, max: 512)
    |> validate_not_self()
    |> validate_from_matches_kind()
    |> foreign_key_constraint(:from_user_id)
    |> foreign_key_constraint(:to_user_id)
    |> unique_constraint(:legacy_id)
    |> check_constraint(:amount, name: :grain_transfers_amount_positive)
    |> check_constraint(:to_user_id, name: :grain_transfers_not_self, message: "不能转给自己")
  end

  defp validate_not_self(changeset) do
    from = get_field(changeset, :from_user_id)
    to = get_field(changeset, :to_user_id)

    if from && from == to,
      do: add_error(changeset, :to_user_id, "不能转给自己"),
      else: changeset
  end

  # grant 是增发,没有付款方;reward/gift 必须有
  defp validate_from_matches_kind(changeset) do
    kind = get_field(changeset, :kind)
    from = get_field(changeset, :from_user_id)

    cond do
      kind == "grant" and not is_nil(from) ->
        add_error(changeset, :from_user_id, "后台发放不应有付款方")

      kind in ~w(reward gift) and is_nil(from) ->
        add_error(changeset, :from_user_id, "缺少付款方")

      true ->
        changeset
    end
  end

  def kinds, do: @kinds
end
