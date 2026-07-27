defmodule Rice.Tsid do
  @moduledoc """
  时间排序的字符串主键。

  与 semi-backend 的 `lib/tsid.rb` **二进制兼容** —— 同字母表、同位宽、同编码,
  两边生成的 ID 可以互相 `parse/1`。

      [ 53 bit 微秒时间戳 ][ 10 bit clock_id ]  ->  base32 编码为 13 个字符

  字母表 `234567abcdefghijklmnopqrstuvwxyz` 按 ASCII 单调递增(`'2'..'7'` = 0x32–0x37,
  `'a'..'z'` = 0x61–0x7a),所以**字符串的字典序等于数值序,也就等于时间序** ——
  这是它能直接当 keyset 分页游标用的原因。

  53 位微秒可用到公元 2255 年。`clock_id` 在 `init/0` 时随机取,用于区分同一微秒内
  并发生成的多个节点;同一节点内的严格递增由 `:atomics` 上的 CAS 循环保证。
  """
  import Bitwise

  @chars ~c"234567abcdefghijklmnopqrstuvwxyz"
  @chars_tuple List.to_tuple(@chars)
  @index_map @chars |> Enum.with_index() |> Map.new()

  @clock_id_bits 10
  @clock_id_max 1 <<< @clock_id_bits
  @length 13

  @type t :: <<_::104>>

  @doc """
  初始化生成器状态:一个用于单调性的 `:atomics` 槽 + 一个随机 `clock_id`。

  由 `Rice.Application.start/2` 在最前面调用。重复调用是安全的(会重置计数器,
  但单调性仍由 `max(now, last + 1)` 保证)。
  """
  @spec init() :: :ok
  def init do
    :persistent_term.put(
      __MODULE__,
      {:atomics.new(1, signed: false), :rand.uniform(@clock_id_max) - 1}
    )
  end

  @doc "生成一个新的 TSID。"
  @spec generate() :: t()
  def generate do
    {ref, clock_id} = state()
    us = monotonic_us(ref, System.os_time(:microsecond))
    encode(us <<< @clock_id_bits ||| clock_id)
  end

  @doc "解析出 `{timestamp_us, clock_id}`。"
  @spec parse(t()) :: {non_neg_integer(), non_neg_integer()}
  def parse(<<_::binary-size(@length)>> = tsid) do
    int = decode(tsid)
    {int >>> @clock_id_bits, int &&& @clock_id_max - 1}
  end

  @doc "TSID 里编码的时间戳,转成 `DateTime`。"
  @spec to_datetime(t()) :: DateTime.t()
  def to_datetime(tsid) do
    {us, _clock_id} = parse(tsid)
    DateTime.from_unix!(us, :microsecond)
  end

  @doc "字符串是否是一个合法的 TSID。"
  @spec valid?(term()) :: boolean()
  def valid?(<<_::binary-size(@length)>> = s),
    do: s |> String.to_charlist() |> Enum.all?(&Map.has_key?(@index_map, &1))

  def valid?(_), do: false

  @doc "把整数编码成 13 个字符(暴露出来是为了跨语言测试向量比对)。"
  @spec encode(non_neg_integer()) :: t()
  def encode(int) when is_integer(int) and int >= 0, do: encode(int, @length, [])

  @doc "把 13 个字符解码回整数。"
  @spec decode(t()) :: non_neg_integer()
  def decode(<<_::binary-size(@length)>> = tsid) do
    tsid
    |> String.to_charlist()
    |> Enum.reduce(0, fn char, acc ->
      case @index_map do
        %{^char => value} -> acc * 32 + value
        _ -> raise ArgumentError, "TSID 中出现非法字符: #{inspect(<<char>>)}"
      end
    end)
  end

  def decode(other),
    do: raise(ArgumentError, "TSID 长度必须是 #{@length},收到 #{inspect(other)}")

  # ── 内部 ────────────────────────────────────────────────────────────────

  # 同一微秒内多次调用时 +1,保证严格递增(对齐 tsid.rb 的 ensure_monotonicity)。
  # CAS 失败说明有并发生成,重读重试。
  defp monotonic_us(ref, now) do
    last = :atomics.get(ref, 1)
    next = max(now, last + 1)

    case :atomics.compare_exchange(ref, 1, last, next) do
      :ok -> next
      _current -> monotonic_us(ref, now)
    end
  end

  defp encode(_int, 0, acc), do: List.to_string(acc)

  defp encode(int, n, acc),
    do: encode(div(int, 32), n - 1, [elem(@chars_tuple, rem(int, 32)) | acc])

  # 正常路径下 init/0 已在应用启动时跑过;这里兜住 mix task / escript 等
  # 没走 Application.start 的场景。
  defp state do
    case :persistent_term.get(__MODULE__, nil) do
      nil ->
        init()
        :persistent_term.get(__MODULE__)

      state ->
        state
    end
  end
end
