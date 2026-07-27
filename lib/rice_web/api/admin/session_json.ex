defmodule RiceWeb.Api.Admin.SessionJSON do
  alias RiceWeb.Api.Admin.AdminUserJSON

  def show(%{admin: admin, token: token}) do
    %{data: %{token: token, admin: AdminUserJSON.data(admin)}}
  end
end
