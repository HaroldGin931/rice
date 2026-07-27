defmodule Rice.Notifications.Smtp do
  @moduledoc """
  SMTP 发信,走 `Rice.Mailer`(Swoosh)。core 用的是 MailKit,配置项一一对应。

  短信不归它管 —— 组合两个通道的活交给 `Rice.Notifications.Dispatcher`。

  配置(见 `config/runtime.exs`):

      config :rice, Rice.Notifications.Smtp,
        sender_name: "乡建DAO", sender_address: "no-reply@xjdao.xyz"
      config :rice, Rice.Mailer,
        adapter: Swoosh.Adapters.SMTP, relay: ..., username: ..., password: ...
  """
  @behaviour Rice.Notifications

  import Swoosh.Email
  require Logger

  @impl true
  def send_sms(_region, _phone, _text), do: {:error, :email_channel_only}

  @impl true
  def send_email(address, subject, body) do
    cfg = Application.get_env(:rice, __MODULE__, [])

    email =
      new()
      |> to(address)
      |> from({cfg[:sender_name] || "乡建DAO", cfg[:sender_address] || "no-reply@xjdao.xyz"})
      |> subject(subject)
      # 正文是我们自己拼的验证码文案,没有用户输入,不需要转义
      |> html_body("<p>#{body}</p>")
      |> text_body(body)

    case Rice.Mailer.deliver(email) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error("[邮件] 发送失败 #{inspect(reason)}")
        {:error, {:smtp, reason}}
    end
  end
end
