defmodule Rice.Notifications.Dispatcher do
  @moduledoc """
  生产用的实现:短信走阿里云,邮件走 SMTP,**任一通道没配就退回日志**。

  为什么要退回而不是报错:rice 的注册、找回密码、改绑、注销全都依赖验证码。
  一个只配了邮件的环境,如果短信通道一配不上就整个崩掉,那连邮箱注册也用不了。
  退回日志意味着本地和预发环境照常能走完流程 —— 验证码打在日志里。

  日志里带一句显眼的告警,免得有人在生产上跑着 Log 通道还不知道。
  """
  @behaviour Rice.Notifications

  require Logger

  alias Rice.Notifications.{AliyunSms, Log, Smtp}

  @impl true
  def send_sms(region, phone, text) do
    if configured?(AliyunSms, [:access_key_id, :access_key_secret, :sign_name, :template_code]) do
      AliyunSms.send_sms(region, phone, text)
    else
      Logger.warning("阿里云短信未配置,验证码只会出现在日志里")
      Log.send_sms(region, phone, text)
    end
  end

  @impl true
  def send_email(address, subject, body) do
    if mailer_configured?() do
      Smtp.send_email(address, subject, body)
    else
      Logger.warning("SMTP 未配置,验证码只会出现在日志里")
      Log.send_email(address, subject, body)
    end
  end

  @doc "四个必填项全都非空才算配好 —— 少一个签名就算不对,发出去是 400。"
  def configured?(mod, keys) do
    cfg = Application.get_env(:rice, mod, [])
    Enum.all?(keys, fn key -> cfg[key] not in [nil, ""] end)
  end

  defp mailer_configured? do
    cfg = Application.get_env(:rice, Rice.Mailer, [])
    cfg[:adapter] not in [nil, Swoosh.Adapters.Local]
  end
end
