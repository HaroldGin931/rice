defmodule Rice.ImportGuardTest do
  @moduledoc """
  `mix rice.import --commit` 的目标库判定。

  这层单独测,是因为它挡的那个错误无法回滚:生产和测试共用同一个 Postgres 实例,
  `rice` 和 `rice_dev` 只差四个字符,判错一次就是把 core 的数据写进生产 rice 库。
  """
  use ExUnit.Case, async: true

  alias Rice.Import

  describe "白名单认哪些" do
    test "以 _dev / _test / _staging 结尾的算测试库" do
      for db <- ~w(rice_dev rice_test rice_staging foo_dev xiangjiandao_test) do
        assert Import.dev_database?(db), "#{db} 应该被当成测试库"
      end
    end

    # 这几个是黑名单版本会**放过**的:host 是 127.0.0.1、库名不含 "prod",
    # 老判定一个都不触发。白名单必须把它们全拦下来。
    test "生产库名一律拦下" do
      for db <- ~w(rice xiangjiandao plc bsky posts) do
        refute Import.dev_database?(db), "#{db} 不该被当成测试库"
      end
    end

    test "只是包含而不是结尾的不算" do
      refute Import.dev_database?("rice_dev_backup")
      refute Import.dev_database?("dev")
      refute Import.dev_database?("development")
    end

    test "空的和非字符串不算" do
      refute Import.dev_database?("")
      refute Import.dev_database?(nil)
    end
  end

  describe "库名从哪里读" do
    # 测试环境本来就连 rice_test,顺带证明这条路径读得对
    test "读得到当前 Repo 连的库" do
      assert Import.target_database() =~ "rice_test"
      assert Import.dev_database?(Import.target_database())
    end
  end
end
