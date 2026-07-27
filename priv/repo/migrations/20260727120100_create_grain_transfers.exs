defmodule Rice.Repo.Migrations.CreateGrainTransfers do
  use Ecto.Migration
  import Rice.Migration

  # 稻米账本。合并了 core 的两张表:
  #
  #   t_point_record            每笔转账写两行(收付各一,score 带符号)
  #   t_point_distribute_record 后台发放,是 t_point_record where type=3 的完整副本
  #
  # 生产实测(§6.4):2528 + 32 行 -> 1280 行,零信息损失。
  # 后台发放在 core 里 participator_id 是零 GUID 占位,这里就是 from_user_id = NULL。
  def change do
    create table(:grain_transfers, primary_key: false) do
      tsid_primary_key()
      add :legacy_id, :string, size: 36
      add :kind, :string, size: 16, null: false
      add :from_user_id, tsid_references(:users, on_delete: :nilify_all)
      add :to_user_id, tsid_references(:users, on_delete: :nilify_all), null: false
      add :amount, :bigint, null: false
      add :memo, :string, size: 256, null: false, default: ""
      # 被打赏的帖子等,at:// URI。core 那边叫 ExtendInfo,是个自由文本字段。
      add :subject_uri, :string, size: 512

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:grain_transfers, [:legacy_id], where: "legacy_id is not null")
    create index(:grain_transfers, [:to_user_id, :id])
    create index(:grain_transfers, [:from_user_id, :id], where: "from_user_id is not null")

    create constraint(:grain_transfers, :grain_transfers_amount_positive, check: "amount > 0")

    create constraint(:grain_transfers, :grain_transfers_kind,
             check: "kind in ('reward', 'gift', 'grant')"
           )

    # 不能给自己转 —— core 只在应用层判断
    create constraint(:grain_transfers, :grain_transfers_not_self,
             check: "from_user_id is null or from_user_id <> to_user_id"
           )

    # grant 是增发(from 为空),reward/gift 必须有付款方
    create constraint(:grain_transfers, :grain_transfers_from_matches_kind,
             check: "(kind = 'grant') = (from_user_id is null)"
           )
  end
end
