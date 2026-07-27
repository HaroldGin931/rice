defmodule Rice.Tsid.Type do
  @moduledoc """
  `Rice.Tsid` 的 Ecto 类型。底层是 `varchar(13)`。

  用在 `Rice.Schema` 里,所有业务表的主键和外键都是它。`cast/1` 会拒绝
  长度或字符不合法的值,所以从 URL 参数进来的垃圾 ID 在 changeset 阶段就被挡掉,
  不会带着走到数据库。
  """
  use Ecto.Type

  @impl true
  def type, do: :string

  @impl true
  def cast(value) when is_binary(value) do
    if Rice.Tsid.valid?(value), do: {:ok, value}, else: :error
  end

  def cast(_), do: :error

  @impl true
  def load(value) when is_binary(value), do: {:ok, value}
  def load(_), do: :error

  @impl true
  def dump(value) when is_binary(value) do
    if Rice.Tsid.valid?(value), do: {:ok, value}, else: :error
  end

  def dump(_), do: :error

  @impl true
  def autogenerate, do: Rice.Tsid.generate()
end
