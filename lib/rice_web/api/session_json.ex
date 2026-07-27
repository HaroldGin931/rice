defmodule RiceWeb.Api.SessionJSON do
  alias RiceWeb.Api.UserJSON

  @doc """
  登录 / 注册的响应。

  `token` 是 rice 自己的令牌;`pds` 那组是 AT Protocol 的会话,
  前端的 Agent 直接用它跟 PDS 说话 —— rice 不代管这组凭据。
  """
  def show(%{user: user, token: token, pds_session: session}) do
    %{
      data: %{
        token: token,
        user: UserJSON.data(user),
        pds: %{
          service: Application.fetch_env!(:rice, :pds)[:public_url],
          did: session["did"],
          handle: session["handle"],
          access_jwt: session["accessJwt"],
          refresh_jwt: session["refreshJwt"]
        }
      }
    }
  end
end
