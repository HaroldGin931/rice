defmodule RiceWeb.Api.ErrorJSON do
  @moduledoc "API 的错误响应。形状固定为 `{\"errors\": ...}`。"

  def render("404.json", _assigns), do: %{errors: %{detail: "不存在"}}
  def render("401.json", _assigns), do: %{errors: %{detail: "未认证"}}
  def render("403.json", _assigns), do: %{errors: %{detail: "无权限"}}
  def render("500.json", _assigns), do: %{errors: %{detail: "服务器内部错误"}}

  @doc "changeset 错误直出成 `{\"errors\": {\"字段\": [\"消息\"]}}`。"
  def render("changeset.json", %{changeset: changeset}) do
    %{errors: Ecto.Changeset.traverse_errors(changeset, &translate_error/1)}
  end

  defp translate_error({msg, opts}) do
    Regex.replace(~r"%\{(\w+)\}", msg, fn _, key ->
      opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
    end)
  end
end
