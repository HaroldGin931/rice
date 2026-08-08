defmodule Rice.Import.Audit do
  @moduledoc """
  §7.3 里跨表的那几项对账。行数对得上不代表内容对得上 —— 这里查的是内容。

    * **提案票数** —— `proposals.agree_count` 是从 core 搬过来的缓存值,
      必须等于 `proposal_votes` 里真实的行数。core 那边这两者一致(§6.4 实测),
      导完还一致才说明投票没漏没重。
    * **唯一性** —— 手机 / 邮箱 / handle / DID 在存活用户里不能重复。
      唯一索引本来就会拦住,但索引是 partial 的(`where deleted_at is null`),
      这里再数一遍是为了确认软删的那几行确实带着 `deleted_at` 进来了。
    * **抽样比对** —— 随机取一批用户,逐字段和 MySQL 比。前面所有检查都是
      聚合数,聚合数对得上、每一行却错位的情况是存在的(比如外键整体平移)。
  """
  import Ecto.Query

  alias Rice.Accounts.User
  alias Rice.Governance.{Proposal, Vote}
  alias Rice.Import.Source
  alias Rice.Repo

  @sample_size 200

  @doc "返回若干条 `%{name:, source:, target:, ok?:}`,和其它模块的对账拼在一起。"
  def reconcile do
    vote_counts() ++ uniqueness() ++ [sample()]
  end

  # ── 提案票数 ────────────────────────────────────────────────────────────

  defp vote_counts do
    actual =
      from(v in Vote,
        group_by: [v.proposal_id, v.choice],
        select: {{v.proposal_id, v.choice}, count(v.id)}
      )
      |> Repo.all()
      |> Map.new()

    mismatched =
      from(p in Proposal, select: {p.id, p.agree_count, p.oppose_count})
      |> Repo.all()
      |> Enum.count(fn {id, agree, oppose} ->
        agree != Map.get(actual, {id, "agree"}, 0) or
          oppose != Map.get(actual, {id, "oppose"}, 0)
      end)

    [entry("提案票数与投票记录不符", 0, mismatched)]
  end

  # ── 唯一性 ──────────────────────────────────────────────────────────────

  defp uniqueness do
    for {label, field} <- [{"手机", :phone}, {"邮箱", :email}, {"handle", :handle}, {"DID", :did}] do
      count =
        from(u in User,
          where: is_nil(u.deleted_at) and not is_nil(field(u, ^field)),
          group_by: field(u, ^field),
          having: count(u.id) > 1,
          select: count(u.id)
        )
        |> Repo.all()
        |> length()

      entry("存活用户重复#{label}", 0, count)
    end
  end

  # ── 抽样 ────────────────────────────────────────────────────────────────

  # 随机而不是取前 N 个:导入是按 MySQL 的返回顺序做的,取前 N 个正好覆盖到
  # 最先处理的那一批,而错位这类问题往往出现在中后段。
  defp sample do
    ids =
      from(u in User, where: not is_nil(u.legacy_id), select: u.legacy_id)
      |> Repo.all()
      |> Enum.take_random(@sample_size)

    mismatched = if ids == [], do: 0, else: count_mismatches(ids)
    entry("抽样比对(#{length(ids)} 个用户)", 0, mismatched)
  end

  defp count_mismatches(ids) do
    placeholders = ids |> Enum.map(fn _ -> "?" end) |> Enum.join(",")

    source =
      Source.query!(
        "SELECT id, did, domain_name, nick_name, score, node_user " <>
          "FROM t_user WHERE id IN (#{placeholders})",
        ids
      )
      |> Map.new(&{&1["id"], &1})

    from(u in User, where: u.legacy_id in ^ids)
    |> Repo.all()
    |> Enum.count(fn user ->
      case Map.fetch(source, user.legacy_id) do
        :error ->
          true

        {:ok, row} ->
          user.did != row["did"] or
            user.handle != row["domain_name"] or
            user.nickname != (row["nick_name"] || "") or
            user.grain_balance != (row["score"] || 0) or
            user.node_member != (row["node_user"] == 1)
      end
    end)
  end

  defp entry(name, source, target),
    do: %{name: name, source: source, target: target, ok?: source == target}
end
