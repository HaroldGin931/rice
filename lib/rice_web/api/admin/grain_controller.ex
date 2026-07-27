defmodule RiceWeb.Api.Admin.GrainController do
  @moduledoc """
  后台发放稻米与查明细。

  core 的 single / batch 在这里是同一个 POST —— 收款人永远是个数组,
  发一个人就是长度为 1。
  """
  use RiceWeb, :controller

  alias Rice.Admin.Grants

  action_fallback RiceWeb.Api.FallbackController

  def index(conn, params), do: render(conn, :index, page: Grants.list_grants(params))

  def create(conn, params) do
    recipients = List.wrap(params["to"])

    case Grants.grant(recipients, params["amount"], memo: params["memo"]) do
      {:ok, count} ->
        conn |> put_status(:created) |> json(%{data: %{granted: count}})

      {:error, {:unknown_recipients, missing}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: %{to: ["这些收款人不存在: " <> Enum.join(missing, ", ")]}})

      {:error, :no_recipients} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: %{to: ["至少要有一个收款人"]}})

      {:error, :invalid_amount} ->
        {:error, :invalid_amount}

      {:error, %Ecto.Changeset{} = cs} ->
        {:error, cs}
    end
  end

  @doc "某个用户的稻米明细。core 是 /admin/score/user-sore-record-page。"
  def transfers(conn, %{"user_id" => user_id} = params) do
    with {:ok, user} <- Rice.Admin.Users.fetch_user(user_id) do
      render(conn, :transfers, page: Rice.Grains.list_transfers(user, params), user: user)
    end
  end
end
