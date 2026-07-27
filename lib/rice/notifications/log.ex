defmodule Rice.Notifications.Log do
  @moduledoc """
  开发环境的实现:只写日志,不真的外发。

  阿里云短信 / SMTP 的真实实现在接生产前补;在那之前本地就靠日志里的验证码走流程。
  """
  @behaviour Rice.Notifications
  require Logger

  @impl true
  def send_sms(region, phone, text) do
    Logger.info("[短信] +#{region}#{phone}: #{text}")
    :ok
  end

  @impl true
  def send_email(address, subject, body) do
    Logger.info("[邮件] #{address} | #{subject} | #{body}")
    :ok
  end
end
