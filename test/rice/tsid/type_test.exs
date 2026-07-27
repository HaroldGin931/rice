defmodule Rice.Tsid.TypeTest do
  use ExUnit.Case, async: true

  alias Rice.Tsid
  alias Rice.Tsid.Type

  test "type/0 是 :string" do
    assert Type.type() == :string
  end

  test "cast/1 接受合法 TSID" do
    tsid = Tsid.generate()
    assert Type.cast(tsid) == {:ok, tsid}
  end

  test "cast/1 拒绝垃圾输入 —— 挡在 changeset,不落库" do
    for bad <- ["", "abc", "222222222222", "222222222222!", "../../etc/passwd", nil, 42, %{}] do
      assert Type.cast(bad) == :error, "不该接受 #{inspect(bad)}"
    end
  end

  test "dump/1 同样校验" do
    tsid = Tsid.generate()
    assert Type.dump(tsid) == {:ok, tsid}
    assert Type.dump("nope") == :error
    assert Type.dump(nil) == :error
  end

  test "load/1 原样返回(库里的值假定已经合法)" do
    assert Type.load("2222222222222") == {:ok, "2222222222222"}
    assert Type.load(42) == :error
  end

  test "autogenerate/0 每次都产出新的合法 TSID" do
    ids = for _ <- 1..100, do: Type.autogenerate()

    assert Enum.all?(ids, &Tsid.valid?/1)
    assert length(Enum.uniq(ids)) == 100
    assert ids == Enum.sort(ids)
  end

  test "cast → dump → load 往返不变" do
    tsid = Tsid.generate()
    assert {:ok, cast} = Type.cast(tsid)
    assert {:ok, dumped} = Type.dump(cast)
    assert {:ok, ^tsid} = Type.load(dumped)
  end
end
