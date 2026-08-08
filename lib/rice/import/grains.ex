defmodule Rice.Import.Grains do
  @moduledoc """
  导入稻米账本。core 的两张表合并成 `grain_transfers` 一张。

  ## 折半

  `t_point_record` 每笔转账写**两行**:收方一行 `score = +N`,付方一行
  `score = -N`,两行的 `user_id` / `participator_id` 互换。rice 一笔就是一行,
  有明确的 `from_user_id` / `to_user_id`。

  导入规则(§6.4④):**只取 `score > 0` 的行**,`to_user_id = user_id`,
  `from_user_id = participator_id`。生产实测 2560 行折成 1280 行。

  折半是有损操作 —— 丢掉的负行必须先证明它确实是冗余的。所以每导一条正行,
  都要能在负行里找到配对的那一条;配不上的会留下警告,并且被
  `reconcile/0` 的"流水配对"那一项数出来。**没有这层断言,折半就是在猜。**

  ## `t_point_distribute_record` 不作为数据源

  它是 `t_point_record where type = 3` 的完整副本(§6.4②:32 行对 32 行,
  金额同为 8,941,666)。作为源导一遍等于把后台发放记两次,所以这里只拿它
  **对账**:两边行数和金额必须相等。

  ## 后台发放没有付款方

  core 的 `participator_id` 在 type=3 上是全零 GUID 占位。rice 里就是
  `from_user_id = NULL`,语义正确且不再需要哨兵值 —— 这也是 §6.4① 里
  那 32 个"外键孤儿"的真相。
  """
  import Ecto.Query
  import Rice.Import.Writer

  alias Rice.Accounts.User
  alias Rice.Grains.Transfer
  alias Rice.Import.Source
  alias Rice.Repo

  # core 的 ScoreSourceType:0 Unknown、1 Reward 打赏、2 Send 赠送、3 后台发放
  @kinds %{1 => "reward", 2 => "gift", 3 => "grant"}

  @doc "跑一遍,返回 `%{grain_transfers: …}`。"
  def import_all do
    users = legacy_map(User)

    rows =
      Source.query!("""
      SELECT id, user_id, participator_id, type, remark, score, created_at, updated_at
        FROM t_point_record WHERE deleted = 0
      """)

    {positive, negative} = Enum.split_with(rows, &(score(&1) > 0))
    {payers, unpaired} = pair(positive, negative)

    report = insert_each(positive, Transfer, &build(&1, users, payers, unpaired))

    # 零金额的行既不是收也不是付,折半规则覆盖不到,单独点名
    zero = Enum.count(rows, &(score(&1) == 0))

    warnings =
      report.warnings ++
        if(zero > 0, do: ["t_point_record 里有 #{zero} 行 score = 0,不属于任何一笔转账"], else: [])

    %{grain_transfers: %{report | warnings: warnings}}
  end

  @doc """
  一行 `t_point_record`(正行)→ 一个 changeset。

  `payers` 是 `pair/2` 配出来的「正行 id → 付款人」,权威;配不上的落在
  `unpaired` 里,退回用正行自己的 `participator_id`,并带警告 ——
  那个字段生产里有错的,所以这是退路而不是首选。
  """
  def build(row, users, payers \\ %{}, unpaired \\ MapSet.new()) do
    payer = Map.get(payers, row["id"], row["participator_id"])

    with {:ok, kind} <- kind(row),
         {:ok, to_id} <- fk(users, row["user_id"], "t_point_record.user_id", row["id"]),
         {:ok, from_id} <- fk(users, payer, "t_point_record 的付款人", row["id"]) do
      changeset =
        %Transfer{}
        |> Transfer.changeset(%{
          legacy_id: row["id"],
          kind: kind,
          # participator_domain_name / participator_nick_name 是 t_user 的副本,不迁。
          # reason 也不迁 —— 它存的就是 kind 的中文描述,没有额外信息。
          from_user_id: from_id,
          to_user_id: to_id,
          amount: score(row),
          memo: row["remark"] || ""
          # subject_uri 没有来源:core 打赏时 Remark 恒为空串,也没存被打赏的帖子
        })
        |> keep_timestamps(row)

      if MapSet.member?(unpaired, row["id"]) do
        {:ok, changeset, "找不到配对的负行,折半后这笔的付方无从核对(行 #{row["id"]})"}
      else
        {:ok, changeset}
      end
    end
  end

  @doc """
  对账。四项:

    * 行数 —— 正行数 == `grain_transfers` 行数
    * 流水配对 —— 配不上负行的正行必须是 0
    * 发放副本 —— `t_point_distribute_record` 与 kind=grant 的行数、金额相等
    * 稻米守恒 —— `sum(users.grain_balance)` == 发放总额(§6.4③:全站稻米
      100% 来自后台发放,打赏和赠送是零和的内部转移)
  """
  def reconcile do
    rows =
      Source.query!("""
      SELECT id, user_id, participator_id, type, remark, score, created_at, updated_at
        FROM t_point_record WHERE deleted = 0
      """)

    {positive, negative} = Enum.split_with(rows, &(score(&1) > 0))
    {_payers, unpaired} = pair(positive, negative)

    [%{"c" => dist_rows, "s" => dist_sum}] =
      Source.query!(
        "SELECT COUNT(*) AS c, COALESCE(SUM(score), 0) AS s " <>
          "FROM t_point_distribute_record WHERE deleted = 0"
      )

    grants = from(t in Transfer, where: t.kind == "grant")

    [
      entry("grain_transfers", length(positive), Repo.aggregate(Transfer, :count)),
      entry("流水配对(未配对数)", 0, MapSet.size(unpaired)),
      entry("发放行数(副本核对)", dist_rows, Repo.aggregate(grants, :count)),
      entry(
        "发放金额(副本核对)",
        to_integer(dist_sum),
        to_integer(Repo.aggregate(grants, :sum, :amount))
      ),
      entry(
        "稻米守恒(余额 vs 发放)",
        to_integer(Repo.aggregate(User, :sum, :grain_balance)),
        to_integer(Repo.aggregate(grants, :sum, :amount))
      )
    ]
  end

  # ── 配对 ────────────────────────────────────────────────────────────────

  @doc """
  把正行和负行配起来。返回 `{%{正行 id => 付款人 legacy_id}, 配不上的正行 id}`。

  ## 付款人取自负行的 `user_id`,不是正行的 `participator_id`

  `user_id` 是这一行**记在谁头上**,余额就是按它加减的,两边都可信;
  `participator_id` 是反规范化的"对方是谁",生产数据里**有 10 笔是错的**
  (2026-08-09 实测):有的把对方记成了不相干的第三个人,有的记成了自己。
  其中 4 笔错在正行上 —— 直接信它就会给 rice 写错付款人。

  钱的流向本身没问题(稻米守恒对得上),错的只是这个副本字段。所以配对之后
  从负行的 `user_id` 取付款人:那是付款人自己那一行,是权威的。

  ## 配对键

  `{type, created_at, |金额|}`,再要求**至少有一边把对方记对了**
  (`负行.participator == 正行.user` 或 `正行.participator == 负行.user`)。
  实测那 10 笔全部满足后半条 —— 两边同时记错的一笔都没有。

  只用金额和时刻会在"同一秒内两笔同额转账"上撞车,所以那个额外条件不是装饰:
  它既是消歧,也是"这确实是一对"的证据。

  配上一条就消耗一条,同一对用户之间同额转两次是正常的,不能让第二条正行
  重复配上已经用掉的那条负行。

  后台发放(type=3)不参与:它是增发,本来就只有正行,没有付款方。
  """
  def pair(positive, negative) do
    index =
      negative
      |> Enum.filter(&paired_type?/1)
      |> Enum.group_by(&pair_key/1)

    {payers, unpaired, _index} =
      positive
      |> Enum.filter(&paired_type?/1)
      |> Enum.reduce({%{}, MapSet.new(), index}, fn row, {payers, unpaired, index} ->
        key = pair_key(row)

        case Enum.split_with(Map.get(index, key, []), &counterparty_agrees?(&1, row)) do
          {[match | rest], others} ->
            {Map.put(payers, row["id"], match["user_id"]), unpaired,
             Map.put(index, key, rest ++ others)}

          {[], _} ->
            {payers, MapSet.put(unpaired, row["id"]), index}
        end
      end)

    {payers, unpaired}
  end

  defp paired_type?(row), do: row["type"] in [1, 2]

  defp pair_key(row), do: {row["type"], row["created_at"], abs(score(row))}

  defp counterparty_agrees?(negative, positive) do
    negative["participator_id"] == positive["user_id"] or
      positive["participator_id"] == negative["user_id"]
  end

  # ── 逐列 ────────────────────────────────────────────────────────────────

  defp kind(row) do
    case Map.fetch(@kinds, row["type"]) do
      {:ok, kind} -> {:ok, kind}
      :error -> {:skip, "type=#{inspect(row["type"])} 不是打赏/赠送/发放,跳过(行 #{row["id"]})"}
    end
  end

  defp score(row), do: to_integer(row["score"])

  defp to_integer(nil), do: 0
  defp to_integer(n) when is_integer(n), do: n
  defp to_integer(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_integer(n) when is_float(n), do: trunc(n)

  defp entry(name, source, target),
    do: %{name: name, source: source, target: target, ok?: source == target}
end
