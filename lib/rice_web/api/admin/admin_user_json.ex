defmodule RiceWeb.Api.Admin.AdminUserJSON do
  alias RiceWeb.Api.AttachmentJSON

  def index(%{page: page}) do
    %{data: Enum.map(page.entries, &data/1), meta: %{next_cursor: page.next_cursor}}
  end

  def show(%{admin: admin}), do: %{data: data(admin)}

  @doc "新建管理员时额外带上初始密码 —— 只有这一次能看到。"
  def created(%{admin: admin, password: password}) do
    %{data: Map.put(data(admin), :initial_password, password)}
  end

  def data(admin) do
    %{
      id: admin.id,
      nickname: admin.nickname,
      email: admin.email,
      phone: admin.phone,
      phone_region: admin.phone_region,
      role: admin.role,
      superuser: admin.superuser,
      avatar: AttachmentJSON.embed(admin.avatar),
      last_login_at: admin.last_login_at,
      inserted_at: admin.inserted_at
    }
  end
end
