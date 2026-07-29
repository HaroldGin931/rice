defmodule Rice.Admin.Grants do
  @moduledoc """
  后台发放稻米。

  core 有 single 和 batch 两个接口:single 收一个手机号/邮箱,batch 收一个
  上传文件的 fileId、由服务端去解析。这里只有一个接口,收一个收款人数组 ——
  解析 Excel 是前端的事,服务端不该为了一个功能长出一个表格解析器。

  **全有或全无**:任何一个收款人解析不出来,整批都不发。
  core 也是这个语义(数量对不上就抛异常),但它是在拿到分布式锁之后才发现的。
  """
  import Ecto.Query

  alias Rice.Accounts.User
  alias Rice.Grains.Transfer
  alias Rice.{Pagination, Repo}

  @doc """
  批量发放。`recipients` 是手机号 / 邮箱 / handle / DID / rice id 的数组。

  一个事务:要么每个人都到账,要么一个都不动。
  """
  def grant(recipients, amount, opts \\ [])

  def grant(recipients, amount, opts) when is_list(recipients) and recipients != [] do
    with :ok <- validate_amount(amount),
         {:ok, users} <- resolve_all(recipients) do
      memo = Keyword.get(opts, :memo, "") || ""

      users
      |> Enum.reduce(Ecto.Multi.new(), fn user, multi ->
        changeset =
          Transfer.changeset(%Transfer{}, %{
            kind: "grant",
            to_user_id: user.id,
            amount: amount,
            memo: memo
          })

        multi
        |> Ecto.Multi.insert({:transfer, user.id}, changeset)
        |> Ecto.Multi.update_all(
          {:credit, user.id},
          from(u in User, where: u.id == ^user.id),
          inc: [grain_balance: amount]
        )
      end)
      |> Repo.transaction()
      |> case do
        {:ok, _} -> {:ok, length(users)}
        {:error, _step, reason, _} -> {:error, reason}
      end
    end
  end

  def grant(_, _, _), do: {:error, :no_recipients}

  defp validate_amount(amount) when is_integer(amount) and amount > 0, do: :ok
  defp validate_amount(_), do: {:error, :invalid_amount}

  # 一次查完再比对,不是一个个查 —— 收款人上千的时候差别很大
  defp resolve_all(recipients) do
    with {:ok, recipients} <- normalize(recipients) do
      found = Enum.map(recipients, &{&1, resolve(&1)})

      case Enum.filter(found, fn {_, user} -> is_nil(user) end) do
        [] -> {:ok, found |> Enum.map(&elem(&1, 1)) |> Enum.uniq_by(& &1.id)}
        missing -> {:error, {:unknown_recipients, Enum.map(missing, &elem(&1, 0))}}
      end
    end
  end

  # `to` 是 JSON 数组,里面可以是任何东西 —— null、数字、嵌套对象都进得来。
  # 不先卡类型,`String.trim/1` 会抛,表现是一个 500 而不是 422。
  #
  # 空字符串直接丢掉:前端从表格里粘一列手机号,末尾常带几个空行。
  defp normalize(recipients) do
    case Enum.reject(recipients, &is_binary/1) do
      [] ->
        case recipients |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq() do
          [] -> {:error, :no_recipients}
          list -> {:ok, list}
        end

      bad ->
        {:error, {:invalid_recipients, bad}}
    end
  end

  defp resolve(identifier) do
    Rice.Accounts.get_public_user(identifier) || by_contact(identifier)
  end

  defp by_contact(identifier) do
    cond do
      String.contains?(identifier, "@") ->
        Repo.one(
          from u in active(),
            where: fragment("lower(?)", u.email) == ^String.downcase(identifier)
        )

      Regex.match?(~r/^\d{5,20}$/, identifier) ->
        Repo.one(from u in active(), where: u.phone == ^identifier)

      true ->
        nil
    end
  end

  defp active, do: from(u in User, where: is_nil(u.deleted_at) and is_nil(u.disabled_at))

  @doc "发放记录。可按收款人和时间范围筛。"
  def list_grants(params \\ %{}) do
    from(t in Transfer,
      where: t.kind == "grant",
      preload: [to_user: :avatar]
    )
    |> filter_recipient(params["q"])
    |> filter_after(params["since"])
    |> filter_before(params["until"])
    |> Pagination.paginate(Repo, Pagination.params(params))
  end

  defp filter_recipient(query, q) when is_binary(q) and q != "" do
    pattern = "%" <> escape_like(String.trim(q)) <> "%"

    from t in query,
      join: u in assoc(t, :to_user),
      where:
        ilike(u.nickname, ^pattern) or ilike(u.email, ^pattern) or ilike(u.phone, ^pattern) or
          ilike(u.handle, ^pattern)
  end

  defp filter_recipient(query, _), do: query

  defp filter_after(query, since) do
    case parse_time(since) do
      {:ok, dt} -> from t in query, where: t.inserted_at >= ^dt
      :error -> query
    end
  end

  defp filter_before(query, until) do
    case parse_time(until) do
      {:ok, dt} -> from t in query, where: t.inserted_at <= ^dt
      :error -> query
    end
  end

  # 时间参数解析不了就当没传 —— 一个手滑的日期不该让整个列表 500
  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> :error
    end
  end

  defp parse_time(_), do: :error

  defp escape_like(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end
end
