defmodule Rice.Grains do
  @moduledoc """
  稻米(积分)。

  **并发扣款不需要分布式锁。** core 为此拉了 Redis
  (`IXiangjiandaoDistributedDisLock`,对付款方和收款方各 acquire 一次,5 秒超时)。
  这里靠一条带条件的 UPDATE:

      update users set grain_balance = grain_balance - $1
      where id = $2 and grain_balance >= $1

  匹配 0 行就是余额不足,整个事务回滚。数据库上还有
  `check (grain_balance >= 0)` 兜底,即使代码写错也不可能出现负余额。
  """
  import Ecto.Query

  alias Ecto.Multi
  alias Rice.Accounts.User
  alias Rice.Grains.Transfer
  alias Rice.{Pagination, Repo}

  @doc """
  转账。`kind` 是 `reward` 或 `gift`。

  返回 `{:ok, transfer}`,或 `{:error, :insufficient_balance | :recipient_not_found |
  :recipient_disabled | changeset}`。
  """
  def transfer(%User{} = from, to_identifier, amount, opts \\ []) do
    with {:ok, to} <- resolve_recipient(to_identifier),
         :ok <- ensure_not_self(from, to) do
      attrs = %{
        kind: Keyword.get(opts, :kind, "gift"),
        from_user_id: from.id,
        to_user_id: to.id,
        amount: amount,
        memo: Keyword.get(opts, :memo, "") || "",
        subject_uri: Keyword.get(opts, :subject_uri)
      }

      changeset = Transfer.changeset(%Transfer{}, attrs)

      Multi.new()
      |> Multi.insert(:transfer, changeset)
      |> Multi.run(:debit, fn repo, _ -> debit(repo, from.id, amount) end)
      |> Multi.run(:credit, fn repo, _ -> credit(repo, to.id, amount) end)
      |> Repo.transaction()
      |> case do
        # 预加载双方 —— 渲染层要用,而且这里刚写完就取,不会有额外一轮查询的惊喜
        {:ok, %{transfer: transfer}} -> {:ok, Repo.preload(transfer, [:from_user, :to_user])}
        {:error, :debit, reason, _} -> {:error, reason}
        {:error, _step, %Ecto.Changeset{} = changeset, _} -> {:error, changeset}
        {:error, _step, reason, _} -> {:error, reason}
      end
    end
  end

  @doc "后台发放(增发)。没有付款方,总量增加。"
  def grant(%User{} = to, amount, opts \\ []) do
    attrs = %{
      kind: "grant",
      to_user_id: to.id,
      amount: amount,
      memo: Keyword.get(opts, :memo, "") || ""
    }

    Multi.new()
    |> Multi.insert(:transfer, Transfer.changeset(%Transfer{}, attrs))
    |> Multi.run(:credit, fn repo, _ -> credit(repo, to.id, amount) end)
    |> Repo.transaction()
    |> case do
      {:ok, %{transfer: transfer}} -> {:ok, Repo.preload(transfer, [:from_user, :to_user])}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  # 这一条 SQL 就是全部的并发控制。`grain_balance >= amount` 让扣款和余额检查
  # 在同一个原子操作里完成,不存在"查完到扣之间被插一脚"的窗口。
  defp debit(repo, user_id, amount) do
    {count, _} =
      repo.update_all(
        from(u in User, where: u.id == ^user_id and u.grain_balance >= ^amount),
        inc: [grain_balance: -amount]
      )

    if count == 1, do: {:ok, count}, else: {:error, :insufficient_balance}
  end

  defp credit(repo, user_id, amount) do
    {count, _} =
      repo.update_all(from(u in User, where: u.id == ^user_id), inc: [grain_balance: amount])

    if count == 1, do: {:ok, count}, else: {:error, :recipient_not_found}
  end

  defp resolve_recipient(%User{} = user), do: {:ok, user}

  # 收款方可以用 rice 的 id、DID、handle、邮箱或手机号指定 —— 转账界面只有
  # 一个输入框,用户填什么都得认。不能把这些塞进一条 or:id 是
  # Rice.Tsid.Type,拿一个 DID 去比会在 dump 阶段直接报错。
  #
  # 注意这里确实能区分「联系方式存在 / 不存在」(找不到会报
  # recipient_not_found)。core 也是如此,而且转账本身必须给出这个反馈 ——
  # 想收敛枚举风险要靠接口限流,不是靠把错误信息含糊掉。
  defp resolve_recipient(identifier) when is_binary(identifier) do
    identifier = String.trim(identifier)

    user =
      find_by_id(identifier) || find_by_did(identifier) || find_by_handle(identifier) ||
        find_by_contact(identifier)

    cond do
      is_nil(user) -> {:error, :recipient_not_found}
      not is_nil(user.disabled_at) -> {:error, :recipient_disabled}
      true -> {:ok, user}
    end
  end

  defp resolve_recipient(_), do: {:error, :recipient_not_found}

  defp find_by_id(identifier) do
    if Rice.Tsid.valid?(identifier) do
      Repo.one(from u in User, where: is_nil(u.deleted_at) and u.id == ^identifier)
    end
  end

  defp find_by_did("did:" <> _ = identifier),
    do: Repo.one(from u in User, where: is_nil(u.deleted_at) and u.did == ^identifier)

  defp find_by_did(_), do: nil

  defp find_by_handle(identifier) do
    Repo.one(
      from u in User,
        where:
          is_nil(u.deleted_at) and fragment("lower(?)", u.handle) == ^String.downcase(identifier)
    )
  end

  # 邮箱大小写不敏感;手机号只比号码本身,不含区号 —— 界面上没地方填区号。
  defp find_by_contact(identifier) do
    cond do
      String.contains?(identifier, "@") ->
        Repo.one(
          from u in User,
            where:
              is_nil(u.deleted_at) and
                fragment("lower(?)", u.email) == ^String.downcase(identifier)
        )

      Regex.match?(~r/^\d{5,20}$/, identifier) ->
        Repo.one(from u in User, where: is_nil(u.deleted_at) and u.phone == ^identifier)

      true ->
        nil
    end
  end

  defp ensure_not_self(%User{id: id}, %User{id: id}), do: {:error, :cannot_transfer_to_self}
  defp ensure_not_self(_, _), do: :ok

  # ── 查询 ────────────────────────────────────────────────────────────────

  @doc "我的稻米明细:收和付都算。按 id 倒序 —— TSID 的字典序就是时间序。"
  def list_transfers(%User{id: id}, params \\ %{}) do
    from(t in Transfer,
      where: t.from_user_id == ^id or t.to_user_id == ^id,
      preload: [:from_user, :to_user]
    )
    |> Pagination.paginate(Repo, Pagination.params(params))
  end

  @doc "后台发放记录(全站公开,原 /score-distribute-record/page)。"
  def list_grants(params \\ %{}) do
    from(t in Transfer, where: t.kind == "grant", preload: [:to_user])
    |> Pagination.paginate(Repo, Pagination.params(params))
  end

  @doc "对账用:全站余额之和应当等于发放总额(reward/gift 是零和的内部转移)。"
  def reconcile do
    balances =
      Repo.one(
        from u in User, where: is_nil(u.deleted_at), select: coalesce(sum(u.grain_balance), 0)
      )

    granted =
      Repo.one(from t in Transfer, where: t.kind == "grant", select: coalesce(sum(t.amount), 0))

    # Postgres 对 bigint 求和返回 numeric,Ecto 映射成 Decimal。
    # 对账数字是整数,直接转回来,免得调用方到处判类型。
    balances = to_integer(balances)
    granted = to_integer(granted)

    %{balances: balances, granted: granted, ok?: balances == granted}
  end

  defp to_integer(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_integer(n) when is_integer(n), do: n
  defp to_integer(nil), do: 0
end
