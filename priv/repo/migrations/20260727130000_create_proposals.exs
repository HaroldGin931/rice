defmodule Rice.Repo.Migrations.CreateProposals do
  use Ecto.Migration
  import Rice.Migration

  # 原 t_proposal。删掉 6 列 initiator_*(did/domain_name/name/email/avatar)——
  # 发起人改个昵称,那些就全是脏数据。改成 user_id 外键。
  # 也删掉 total_votes(= agree + oppose,存三份就是三份不一致的机会)。
  def change do
    create table(:proposals, primary_key: false) do
      tsid_primary_key()
      add :legacy_id, :string, size: 36
      add :user_id, tsid_references(:users, on_delete: :nilify_all)
      add :title, :string, size: 128, null: false
      add :attachment_id, tsid_references(:attachments, on_delete: :nilify_all)
      add :closes_at, :utc_datetime_usec, null: false
      # core 的 ProposalStatus 是 int 且 0 = Unknown;而且前后端枚举值本来就对不齐
      # (后端 Review/Pass/Oppose,前端 InProgress/Pass/Fail)。换成字符串顺手解决。
      add :status, :string, size: 16, null: false, default: "open"
      add :agree_count, :bigint, null: false, default: 0
      add :oppose_count, :bigint, null: false, default: 0
      add :listed, :boolean, null: false, default: true
      add :deleted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:proposals, [:legacy_id], where: "legacy_id is not null")
    create index(:proposals, [:user_id, :id])
    create index(:proposals, [:status, :id])
    # 结票任务每分钟扫一次这个条件
    create index(:proposals, [:closes_at], where: "status = 'open' and deleted_at is null")

    create constraint(:proposals, :proposals_status,
             check: "status in ('open', 'passed', 'rejected')"
           )

    create constraint(:proposals, :proposals_counts_non_negative,
             check: "agree_count >= 0 and oppose_count >= 0"
           )

    create table(:proposal_votes, primary_key: false) do
      tsid_primary_key()
      add :legacy_id, :string, size: 36
      add :proposal_id, tsid_references(:proposals, on_delete: :delete_all), null: false
      add :user_id, tsid_references(:users, on_delete: :delete_all), null: false
      add :choice, :string, size: 8, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:proposal_votes, [:legacy_id], where: "legacy_id is not null")
    # core 没有这个约束 —— 靠应用层查重,并发可重复投票
    create unique_index(:proposal_votes, [:proposal_id, :user_id])

    create constraint(:proposal_votes, :proposal_votes_choice,
             check: "choice in ('agree', 'oppose')"
           )

    create table(:proposal_comments, primary_key: false) do
      tsid_primary_key()
      # core 这张表的主键是 bigint,不是 uuid;导入时转成十进制字符串
      add :legacy_id, :string, size: 36
      add :proposal_id, tsid_references(:proposals, on_delete: :delete_all), null: false
      add :user_id, tsid_references(:users, on_delete: :nilify_all)
      add :body, :string, size: 512, null: false
      add :deleted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:proposal_comments, [:legacy_id], where: "legacy_id is not null")
    create index(:proposal_comments, [:proposal_id, :id])
  end
end
