defmodule RiceWeb.Api.Admin.SettingsController do
  @moduledoc """
  全站配置。core 有 detail + modify-foundation-info + modify-proposal-config
  三个接口,改的却是同一行 —— 这里是 GET 和 PATCH 各一个。
  """
  use RiceWeb, :controller

  action_fallback RiceWeb.Api.FallbackController

  def show(conn, _params), do: render(conn, :show, site: Rice.Settings.get_site())

  def update(conn, params) do
    attrs =
      Map.take(params, ~w(fund_scale issued_grain_scale proposal_approval_votes document_ids))

    with {:ok, site} <- Rice.Settings.update_site(attrs) do
      render(conn, :show, site: site)
    end
  end
end
