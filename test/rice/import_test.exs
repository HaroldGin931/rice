defmodule Rice.ImportTest do
  @moduledoc """
  整条导入链路,喂一份形状和生产一致的小数据集。

  只有取数那一层是假的(`Rice.FakeImportSource`),changeset、唯一索引、CHECK
  约束、外键解析顺序、对账查询全部是真的,打在真的 Postgres 上。桩打在这条线上
  是有意的:导入的风险不在能不能连上 MySQL,而在映射和约束。

  数据集刻意复刻了 §6.4 里那几条对设计有影响的实测结论:软删用户与存活用户
  撞 handle 和手机号、投票指向软删的提案、后台发放的 participator 是全零 GUID、
  流水成对且可以折半。
  """
  use Rice.DataCase, async: false

  alias Rice.Accounts.User
  alias Rice.Community.{Badge, BadgeAward, Node}
  alias Rice.FakeImportSource, as: Fake
  alias Rice.Governance.{Comment, Proposal, Vote}
  alias Rice.Grains.Transfer

  @zero_guid "00000000-0000-0000-0000-000000000000"

  setup do
    Application.put_env(:rice, :import_source, Fake)
    on_exit(fn -> Application.delete_env(:rice, :import_source) end)
    load_fixture()
    :ok
  end

  describe "干净的数据集" do
    test "对账全绿" do
      {:ok, %{reconciliation: reconciliation}} = Rice.Import.run(true)

      failed = Enum.reject(reconciliation, & &1.ok?)
      assert failed == [], "对账没过:#{inspect(failed)}"
    end

    test "报告里每张表都有,且没有意外的警告" do
      {:ok, %{report: report}} = Rice.Import.run(true)

      for table <- Rice.Import.order() do
        assert Map.has_key?(report, table), "报告里缺 #{table}"
      end

      warnings = report |> Map.values() |> Enum.flat_map(& &1.warnings)
      assert warnings == [], "不该有警告:#{inspect(warnings)}"
    end
  end

  describe "用户" do
    setup do
      {:ok, _} = Rice.Import.run(true)
      :ok
    end

    # §6.4⑤:软删用户与存活用户之间有 handle 和手机号冲突,不导的话下游断链,
    # 而唯一索引带着 `where deleted_at is null` 正是为了让两者共存
    test "软删的用户也导进来,并且和存活用户撞 handle / 手机号也插得进去" do
      assert Repo.aggregate(User, :count) == 3

      deleted = Repo.get_by!(User, legacy_id: "u3")
      assert deleted.deleted_at
      assert deleted.handle == "a.web5.test"
      assert deleted.phone == "13800000001"

      live = Repo.get_by!(User, legacy_id: "u1")
      refute live.deleted_at
      assert live.handle == deleted.handle
      assert live.phone == deleted.phone
    end

    test "余额、节点身份、昵称、时间戳照搬" do
      user = Repo.get_by!(User, legacy_id: "u1")

      assert user.grain_balance == 300
      assert user.node_member
      assert user.nickname == "甲"
      assert user.did == "did:plc:u1"
      assert DateTime.to_date(user.inserted_at) == ~D[2025-03-04]
    end

    test "空字符串的联系方式变成 null" do
      assert Repo.get_by!(User, legacy_id: "u2").email == nil
    end
  end

  describe "稻米账本" do
    setup do
      {:ok, _} = Rice.Import.run(true)
      :ok
    end

    # 2 条发放 + 1 笔赠送的正行 = 3;赠送的负行被折掉
    test "折半:只留正行" do
      assert Repo.aggregate(Transfer, :count) == 3
      refute Repo.get_by(Transfer, legacy_id: "p4"), "负行不该被导进来"
    end

    test "后台发放没有付款方 —— 全零 GUID 变成 NULL" do
      grant = Repo.get_by!(Transfer, legacy_id: "p1")

      assert grant.kind == "grant"
      assert grant.from_user_id == nil
      assert grant.amount == 400
    end

    test "赠送的收付双方对得上" do
      gift = Repo.get_by!(Transfer, legacy_id: "p3")
      from = Repo.get_by!(User, legacy_id: "u1")
      to = Repo.get_by!(User, legacy_id: "u2")

      assert gift.kind == "gift"
      assert gift.from_user_id == from.id
      assert gift.to_user_id == to.id
      assert gift.amount == 100
      assert gift.memo == "生日快乐"
    end

    # §6.4③:全站稻米 100% 来自后台发放,打赏赠送是零和的内部转移
    test "稻米守恒" do
      # bigint 的 SUM 回来是 Decimal —— 对账那边也是这么处理的
      balances = Repo.aggregate(User, :sum, :grain_balance) |> Decimal.to_integer()
      grants = Repo.aggregate(from(t in Transfer, where: t.kind == "grant"), :sum, :amount)

      assert balances == 500
      assert Decimal.to_integer(grants) == 500
    end
  end

  describe "提案 / 投票 / 评论" do
    setup do
      {:ok, _} = Rice.Import.run(true)
      :ok
    end

    # core 的 ProposalStatus 是 int,枚举错一位就是每条提案的状态都标错,
    # 而行数对账完全看不出来
    test "状态枚举映射" do
      assert Repo.get_by!(Proposal, legacy_id: "pr1").status == "open"
      assert Repo.get_by!(Proposal, legacy_id: "pr2").status == "passed"
    end

    test "软删的提案带着 deleted_at 导进来" do
      assert Repo.aggregate(Proposal, :count) == 2
      assert Repo.get_by!(Proposal, legacy_id: "pr2").deleted_at
      refute Repo.get_by!(Proposal, legacy_id: "pr1").deleted_at
    end

    # 提案连软删一起导,附件的收集却曾经带着 `deleted = 0` —— 两个范围一错位,
    # 软删提案的 attachment_id 就全是 null,而**每一项行数对账都是绿的**:
    # 提案数对、附件数也对,少的是"关联"不是"行"。
    test "软删提案的附件也跟着导,关联得上" do
      proposal = Repo.get_by!(Proposal, legacy_id: "pr2")

      assert proposal.attachment_id
      assert Repo.get!(Rice.Files.Attachment, proposal.attachment_id).legacy_id == "2-pr2-方案.pdf"
    end

    # §6.4⑥:29 条投票指向软删的提案。不导软删提案的话这些投票外键解析不到
    test "指向软删提案的投票也导得进来" do
      assert Repo.aggregate(Vote, :count) == 3

      vote = Repo.get_by!(Vote, legacy_id: "v3")
      assert vote.proposal_id == Repo.get_by!(Proposal, legacy_id: "pr2").id
    end

    test "投票选项枚举映射" do
      assert Repo.get_by!(Vote, legacy_id: "v1").choice == "agree"
      assert Repo.get_by!(Vote, legacy_id: "v2").choice == "oppose"
    end

    test "评论的 legacy_id 是 bigint 转成的字符串,软删的也导" do
      assert Repo.aggregate(Comment, :count) == 2
      assert Repo.get_by!(Comment, legacy_id: "1").body == "评论一"
      assert Repo.get_by!(Comment, legacy_id: "2").deleted_at
    end
  end

  # 「创建时间」这一列在 rice 的公告 / 应用 JSON 里是直接给前端的。
  # 期 1 那三张表的导入器当初没跟着加 keep_timestamps,导进来全变成导入那一刻,
  # 而其余每张表都是照搬的 —— 同一个库里两套规则。
  describe "内容位的时间戳也照搬" do
    setup do
      {:ok, _} = Rice.Import.run(true)
      :ok
    end

    test "apps / banners / announcements 的创建时间来自 core,不是导入时刻" do
      for {schema, legacy} <- [
            {Rice.Content.App, "app1"},
            {Rice.Content.Banner, "b1"},
            {Rice.Content.Announcement, "i1"}
          ] do
        record = Repo.get_by!(schema, legacy_id: legacy)

        assert DateTime.to_date(record.inserted_at) == ~D[2025-03-04],
               "#{inspect(schema)} 的 inserted_at 是 #{record.inserted_at}"

        assert DateTime.to_date(record.updated_at) == ~D[2025-03-05]
      end
    end
  end

  describe "节点与勋章" do
    setup do
      {:ok, _} = Rice.Import.run(true)
      :ok
    end

    test "节点挂在节点主身上" do
      node = Repo.get_by!(Node, legacy_id: "n1")
      assert node.user_id == Repo.get_by!(User, legacy_id: "u1").id
      assert node.name == "节点一"
    end

    test "勋章和发放记录" do
      badge = Repo.get_by!(Badge, legacy_id: "m1")
      assert badge.name == "勋章一"
      assert Rice.Community.badge_holder_count(badge) == 2
      assert Repo.aggregate(BadgeAward, :count) == 2
    end
  end

  describe "幂等" do
    # "提前预导 → 切换日只跑增量" 全靠这条
    test "跑两遍不会多出任何一行" do
      {:ok, _} = Rice.Import.run(true)

      counts = fn ->
        Map.new([User, Proposal, Vote, Comment, Transfer, Node, Badge, BadgeAward], fn schema ->
          {schema, Repo.aggregate(schema, :count)}
        end)
      end

      first = counts.()
      {:ok, %{reconciliation: reconciliation}} = Rice.Import.run(true)

      assert counts.() == first
      assert Enum.all?(reconciliation, & &1.ok?)
    end
  end

  describe "dry-run" do
    test "什么都不留下,但报告是真的" do
      {:ok, %{report: report, reconciliation: reconciliation}} = Rice.Import.run(false)

      # 报告是在回滚**之前**算的,所以数字是真的
      assert report.users.inserted == 3
      assert Enum.all?(reconciliation, & &1.ok?)

      # 但库里什么都没有
      assert Repo.aggregate(User, :count) == 0
      assert Repo.aggregate(Transfer, :count) == 0
    end
  end

  # 生产实测(2026-08-09):1264 笔非发放流水里有 10 笔的 participator_id 是错的
  # —— 有的指向不相干的第三个人,有的指向自己。钱的流向没问题(user_id 和 score
  # 两边都对,稻米守恒也对得上),错的只是这个反规范化的副本字段。
  describe "付款人取自负行,不信正行的 participator_id" do
    setup do
      # 正行说「我从 u3 收的」,但真正付钱的是 u1(负行的 user_id)
      Fake.put("t_point_record", [
        point_record("p1", "u1", @zero_guid, 3, 400, ""),
        point_record("p2", "u2", @zero_guid, 3, 100, ""),
        %{
          point_record("p3", "u2", "u3", 2, 100, "记错了对方")
          | "created_at" => ~N[2025-05-05 05:05:05]
        },
        %{
          point_record("p4", "u1", "u2", 2, -100, "记错了对方")
          | "created_at" => ~N[2025-05-05 05:05:05]
        }
      ])

      {:ok, _} = Rice.Import.run(true)
      :ok
    end

    test "付款人是负行的 user_id,不是正行写的那个人" do
      gift = Repo.get_by!(Transfer, legacy_id: "p3")

      assert gift.from_user_id == Repo.get_by!(User, legacy_id: "u1").id
      refute gift.from_user_id == Repo.get_by!(User, legacy_id: "u3").id
      assert gift.to_user_id == Repo.get_by!(User, legacy_id: "u2").id
    end

    # 一边记错了照样配得上,因为另一边是对的(负行的 participator 指向 u2 = 收方)
    test "配对仍然成立,不报未配对" do
      {:ok, %{report: report, reconciliation: reconciliation}} = Rice.Import.run(true)

      assert report.grain_transfers.warnings == []
      assert Enum.find(reconciliation, &(&1.name =~ "流水配对")).ok?
    end
  end

  describe "脏数据" do
    test "配不上负行的正行照导,但记警告并且对账标红" do
      # 一条凭空出现的打赏收方行,没有对应的付方行
      Fake.put(
        "t_point_record",
        Fake.rows("t_point_record") ++
          [
            point_record("p9", "u2", "u1", 1, 50, "")
          ]
      )

      {:ok, %{report: report, reconciliation: reconciliation}} = Rice.Import.run(true)

      assert Enum.any?(report.grain_transfers.warnings, &(&1 =~ "找不到配对的负行"))

      pairing = Enum.find(reconciliation, &(&1.name =~ "流水配对"))
      assert pairing.target == 1
      refute pairing.ok?
    end

    test "外键解析不到的行不进库,并且点名到列和行" do
      Fake.put(
        "t_vote_record",
        Fake.rows("t_vote_record") ++
          [
            %{
              "id" => "v9",
              "proposal_id" => "pr1",
              "user_id" => "查无此人",
              "choice" => 1,
              "deleted" => 0,
              "created_at" => ~N[2025-05-01 00:00:00],
              "updated_at" => ~N[2025-05-01 00:00:00]
            }
          ]
      )

      {:ok, %{report: report}} = Rice.Import.run(true)

      assert Enum.any?(
               report.proposal_votes.warnings,
               &(&1 =~ "t_vote_record.user_id" and &1 =~ "v9")
             )

      assert Repo.aggregate(Vote, :count) == 3
    end

    # 投票的 Unknown 记成同意还是反对都是在替用户表态
    test "choice=0 的投票跳过" do
      Fake.put(
        "t_vote_record",
        Enum.map(Fake.rows("t_vote_record"), &Map.put(&1, "choice", 0))
      )

      {:ok, %{report: report}} = Rice.Import.run(true)

      assert Repo.aggregate(Vote, :count) == 0
      assert length(report.proposal_votes.warnings) == 3
    end

    # 提案的 Unknown 相反 —— 跳过等于丢一条提案,导进来最多是状态保守
    test "status=0 的提案照导,当成 open 并留警告" do
      Fake.put(
        "t_proposal",
        Enum.map(Fake.rows("t_proposal"), &Map.put(&1, "status", 0))
      )

      {:ok, %{report: report}} = Rice.Import.run(true)

      assert Repo.aggregate(Proposal, :count) == 2
      assert Enum.all?(Repo.all(Proposal), &(&1.status == "open"))
      assert Enum.count(report.proposals.warnings, &(&1 =~ "当成 open")) == 2
    end

    test "用户头像列里的 PDS blob URL 只报一条汇总警告,不是一人一条" do
      Fake.put(
        "t_user",
        Enum.map(Fake.rows("t_user"), &Map.put(&1, "avatar", "https://pds.test/blob/#{&1["id"]}"))
      )

      {:ok, %{report: report}} = Rice.Import.run(true)

      blob_warnings = Enum.filter(report.attachments.warnings, &(&1 =~ "t_user.avatar"))
      assert [one] = blob_warnings
      assert one =~ "3 个值不是 fileId"
    end
  end

  # ── 数据集 ──────────────────────────────────────────────────────────────

  defp load_fixture do
    Fake.put("t_app", [
      row(%{
        "id" => "app1",
        "name" => "应用一",
        "desc" => "",
        "logo" => "1-a1-app.png",
        "link" => "https://a.test",
        "sort" => 0
      })
    ])

    Fake.put("t_banner", [
      row(%{
        "id" => "b1",
        "banner_file_id" => "1-b1-banner.png",
        "link_address" => "",
        "sort" => 0
      })
    ])

    Fake.put("t_information", [
      row(%{"id" => "i1", "name" => "公告一", "attach_id" => "2-i1-notice.pdf", "sort" => 0})
    ])

    Fake.put("t_global_config", [
      row(%{
        "id" => "g1",
        "fund_scale" => 1,
        "issue_points_scale" => 2,
        "foundation_public_document" => nil,
        "proposal_approval_votes" => 3
      })
    ])

    Fake.put("t_admin_user", [
      row(%{
        "id" => "ad1",
        "email" => "admin@example.com",
        "phone" => "13900000001",
        "phone_region" => "86",
        "avatar" => "",
        "role" => 1,
        "special" => 0,
        "secret_data" => Jason.encode!(%{"Value" => "aGFzaA==", "Salt" => "c2FsdHNhbHRzYWx0c2E="})
      })
    ])

    Fake.put("t_user", [
      user_row("u1", "甲", "13800000001", "a.web5.test", 300, node: 1),
      user_row("u2", "乙", "13800000002", "b.web5.test", 200, email: ""),
      # 软删,且 handle 和手机号都和 u1 撞 —— §6.4⑤ 的形状
      user_row("u3", "丙", "13800000001", "a.web5.test", 0, deleted: 1)
    ])

    Fake.put("t_node", [
      row(%{
        "id" => "n1",
        "user_id" => "u1",
        "user_did" => "did:plc:u1",
        "logo" => "",
        "name" => "节点一",
        "description" => "第一个节点",
        "sort" => 0
      })
    ])

    Fake.put("t_medal", [row(%{"id" => "m1", "attach_id" => "", "name" => "勋章一"})])

    Fake.put("t_user_medal", [
      row(%{
        "id" => "um1",
        "user_id" => "u1",
        "medal_id" => "m1",
        "get_time" => ~N[2025-04-01 00:00:00]
      }),
      row(%{
        "id" => "um2",
        "user_id" => "u2",
        "medal_id" => "m1",
        "get_time" => ~N[2025-04-02 00:00:00]
      })
    ])

    Fake.put("t_proposal", [
      row(%{
        "id" => "pr1",
        "name" => "提案一",
        "initiator_id" => "u1",
        "end_at" => ~N[2030-01-01 00:00:00],
        "attach_id" => "",
        "agree_votes" => 1,
        "oppose_votes" => 1,
        "status" => 1,
        "on_shelf" => 1
      }),
      row(%{
        "id" => "pr2",
        "name" => "提案二",
        "initiator_id" => "u2",
        "end_at" => ~N[2025-06-01 00:00:00],
        # 软删提案也有附件 —— 附件的收集范围必须和导入范围一致
        "attach_id" => "2-pr2-方案.pdf",
        "agree_votes" => 1,
        "oppose_votes" => 0,
        "status" => 2,
        "on_shelf" => 1,
        "deleted" => 1
      })
    ])

    Fake.put("t_vote_record", [
      row(%{"id" => "v1", "proposal_id" => "pr1", "user_id" => "u1", "choice" => 1}),
      row(%{"id" => "v2", "proposal_id" => "pr1", "user_id" => "u2", "choice" => 2}),
      # 指向软删的提案 —— §6.4⑥ 的形状
      row(%{"id" => "v3", "proposal_id" => "pr2", "user_id" => "u1", "choice" => 1})
    ])

    Fake.put("t_proposal_comment", [
      row(%{"id" => 1, "proposal_id" => "pr1", "user_id" => "u1", "content" => "评论一"}),
      row(%{
        "id" => 2,
        "proposal_id" => "pr1",
        "user_id" => "u2",
        "content" => "删掉的",
        "deleted" => 1
      })
    ])

    Fake.put("t_point_record", [
      point_record("p1", "u1", @zero_guid, 3, 400, ""),
      point_record("p2", "u2", @zero_guid, 3, 100, ""),
      # 赠送:收方正行 + 付方负行,两个 id 互换
      point_record("p3", "u2", "u1", 2, 100, "生日快乐"),
      point_record("p4", "u1", "u2", 2, -100, "生日快乐")
    ])

    Fake.put("t_point_distribute_record", [
      row(%{"id" => "d1", "user_id" => "u1", "score" => 400}),
      row(%{"id" => "d2", "user_id" => "u2", "score" => 100})
    ])
  end

  defp row(attrs) do
    Enum.into(attrs, %{
      "deleted" => 0,
      "created_at" => ~N[2025-03-04 05:06:07],
      "updated_at" => ~N[2025-03-05 05:06:07]
    })
  end

  defp user_row(id, nickname, phone, handle, score, opts) do
    row(%{
      "id" => id,
      "did" => "did:plc:#{id}",
      "domain_name" => handle,
      "nick_name" => nickname,
      "introduction" => "",
      "email" => Keyword.get(opts, :email, "#{id}@example.com"),
      "phone" => phone,
      "phone_region" => "86",
      "avatar" => "",
      "score" => score,
      "node_user" => Keyword.get(opts, :node, 0),
      "disable" => 0,
      "deleted" => Keyword.get(opts, :deleted, 0)
    })
  end

  defp point_record(id, user_id, participator_id, type, score, remark) do
    row(%{
      "id" => id,
      "user_id" => user_id,
      "participator_id" => participator_id,
      "type" => type,
      "score" => score,
      "remark" => remark
    })
  end
end
