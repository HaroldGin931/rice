defmodule Rice.Import.Governance do
  @moduledoc """
  导入 `t_proposal` / `t_vote_record` / `t_proposal_comment`。

  ## 软删的提案也导

  生产实测(§6.4⑥):21 个提案里 8 个是软删的,而 **29 条投票指向软删的提案**。
  只导存活提案的话这 29 条投票的外键就解析不到 —— 而外键解析失败是硬错误。
  评论同理。投票本身没有软删列,只取 `deleted = 0`。

  ## 六列发起人副本全部丢掉

  `initiator_did` / `initiator_domain_name` / `initiator_name` /
  `initiator_email` / `initiator_avatar` 都是 `t_user` 的副本,发起人改个昵称
  它们就是脏数据。rice 只留 `user_id` 外键。`total_votes` 也丢掉 ——
  它等于同意加反对,存第三份只是多一个不一致的机会。
  """
  import Rice.Import.Writer

  alias Rice.Accounts.User
  alias Rice.Files.Attachment
  alias Rice.Governance.{Comment, Proposal, Vote}
  alias Rice.Import.Source
  alias Rice.Repo

  # core 的 ProposalStatus:0 Unknown、1 Review、2 Pass、3 Oppose
  @statuses %{1 => "open", 2 => "passed", 3 => "rejected"}
  # core 的 VoteType:0 Unknown、1 Agree、2 Oppose
  @choices %{1 => "agree", 2 => "oppose"}

  @doc "跑一遍,返回 proposals / proposal_votes / proposal_comments 三段报告。"
  def import_all do
    users = legacy_map(User)

    proposals = import_proposals(users, legacy_map(Attachment))
    # 投票和评论都挂在提案上,要等提案建完
    ids = legacy_map(Proposal)

    %{
      proposals: proposals,
      proposal_votes: import_votes(users, ids),
      proposal_comments: import_comments(users, ids)
    }
  end

  def reconcile do
    # 提案和评论连软删一起导,分母是全部行;投票只导存活的
    [%{"c" => proposals}] = Source.query!("SELECT COUNT(*) AS c FROM t_proposal")
    [%{"c" => comments}] = Source.query!("SELECT COUNT(*) AS c FROM t_proposal_comment")

    [
      entry("proposals(含软删)", proposals, Repo.aggregate(Proposal, :count)),
      entry("proposal_votes", Source.count!("t_vote_record"), Repo.aggregate(Vote, :count)),
      entry("proposal_comments(含软删)", comments, Repo.aggregate(Comment, :count))
    ]
  end

  # ── 提案 ────────────────────────────────────────────────────────────────

  defp import_proposals(users, attachments) do
    rows =
      Source.query!("""
      SELECT id, name, initiator_id, end_at, attach_id, oppose_votes, agree_votes,
             status, on_shelf, deleted, created_at, updated_at
        FROM t_proposal
      """)

    insert_each(rows, Proposal, fn row ->
      with {:ok, user_id} <- fk(users, row["initiator_id"], "t_proposal.initiator_id", row["id"]) do
        changeset =
          %Proposal{}
          |> Proposal.changeset(%{
            legacy_id: row["id"],
            user_id: user_id,
            title: row["name"],
            attachment_id: Map.get(attachments, blank_to_nil(row["attach_id"])),
            closes_at: row["end_at"],
            status: status(row),
            agree_count: row["agree_votes"] || 0,
            oppose_count: row["oppose_votes"] || 0,
            listed: truthy?(row["on_shelf"])
          })
          |> Ecto.Changeset.force_change(:deleted_at, usec(deleted_at(row)))
          |> keep_timestamps(row)

        case proposal_warnings(row) do
          [] -> {:ok, changeset}
          warnings -> {:ok, changeset, warnings}
        end
      end
    end)
  end

  # core 的 Unknown = 0 是没初始化的脏值。这里和管理员的 role 处理得不一样 ——
  # 提案是内容不是权限:跳过等于丢一条提案,而当成"审议中"最多是状态显示得
  # 保守一点。所以照常导,但留一条警告让人去核。
  defp status(row), do: Map.get(@statuses, row["status"], "open")

  defp proposal_warnings(row) do
    Enum.reject(
      [
        unless(Map.has_key?(@statuses, row["status"]),
          do: "status=#{inspect(row["status"])} 不是 Review/Pass/Oppose,当成 open 导入(行 #{row["id"]})"
        ),
        # core 的 end_at 默认值是 '0001-01-01 00:00:00' —— 没设过截止时间的提案。
        # 导进来会是一个早已过期的提案,开了 Oban 之后会被结票任务扫到。
        if(sentinel_date?(row["end_at"]),
          do: "end_at 是 0001-01-01 哨兵值,导进来就是已过期的提案(行 #{row["id"]})"
        )
      ],
      &is_nil/1
    )
  end

  defp sentinel_date?(%NaiveDateTime{year: year}), do: year < 1900
  defp sentinel_date?(%DateTime{year: year}), do: year < 1900
  defp sentinel_date?(_), do: false

  # ── 投票 ────────────────────────────────────────────────────────────────

  defp import_votes(users, proposals) do
    rows =
      Source.query!("""
      SELECT id, proposal_id, user_id, choice, created_at, updated_at
        FROM t_vote_record WHERE deleted = 0
      """)

    insert_each(rows, Vote, fn row ->
      with {:ok, proposal_id} <-
             fk(proposals, row["proposal_id"], "t_vote_record.proposal_id", row["id"]),
           {:ok, user_id} <- fk(users, row["user_id"], "t_vote_record.user_id", row["id"]),
           {:ok, choice} <- choice(row) do
        {:ok,
         %Vote{}
         |> Vote.changeset(%{
           legacy_id: row["id"],
           proposal_id: proposal_id,
           user_id: user_id,
           choice: choice
         })
         |> keep_timestamps(row)}
      end
    end)
  end

  # 投票的 Unknown 没法猜 —— 记成同意还是反对都是在替用户表态,跳过
  defp choice(row) do
    case Map.fetch(@choices, row["choice"]) do
      {:ok, choice} -> {:ok, choice}
      :error -> {:skip, "choice=#{inspect(row["choice"])} 不是同意/反对,跳过(行 #{row["id"]})"}
    end
  end

  # ── 评论 ────────────────────────────────────────────────────────────────

  defp import_comments(users, proposals) do
    # 这张表的主键是 bigint 自增,不是 uuid;legacy_id 存十进制字符串
    rows =
      Source.query!("""
      SELECT id, proposal_id, user_id, content, deleted, created_at
        FROM t_proposal_comment
      """)

    insert_each(rows, Comment, fn row ->
      with {:ok, proposal_id} <-
             fk(proposals, row["proposal_id"], "t_proposal_comment.proposal_id", row["id"]),
           {:ok, user_id} <- fk(users, row["user_id"], "t_proposal_comment.user_id", row["id"]) do
        {:ok,
         %Comment{}
         |> Comment.changeset(%{
           # user_name 不迁 —— 又一列 t_user 的副本
           legacy_id: to_string(row["id"]),
           proposal_id: proposal_id,
           user_id: user_id,
           body: row["content"]
         })
         |> Ecto.Changeset.force_change(:deleted_at, usec(deleted_at(row)))
         |> keep_timestamps(row)}
      end
    end)
  end

  # ── 公共 ────────────────────────────────────────────────────────────────

  defp entry(name, source, target),
    do: %{name: name, source: source, target: target, ok?: source == target}

  # deleted_at 走 force_change(不在 changeset 的 cast 列表里),所以要自己补精度
  defp usec(nil), do: nil
  defp usec(%DateTime{} = dt), do: %{dt | microsecond: {elem(dt.microsecond, 0), 6}}
  defp usec(%NaiveDateTime{} = n), do: n |> DateTime.from_naive!("Etc/UTC") |> usec()
end
