defmodule Rice.SchemaTest.Widget do
  @moduledoc false
  use Rice.Schema

  schema "schema_test_widgets" do
    field :name, :string
    field :legacy_id, :string
    belongs_to :parent, __MODULE__
    timestamps()
  end

  def changeset(widget, attrs) do
    widget
    |> cast(attrs, [:name, :legacy_id, :parent_id])
    |> validate_required([:name])
    |> foreign_key_constraint(:parent_id)
    |> unique_constraint(:legacy_id, name: :schema_test_widgets_legacy_idx)
  end
end

defmodule Rice.SchemaTest do
  @moduledoc """
  `Rice.Schema` + `Rice.Tsid.Type` + `tsid` domain 三者接起来是否真的能用。
  表在 sandbox 事务里现建现用,测完随事务回滚,不留痕迹。
  """
  use Rice.DataCase, async: true

  import Ecto.Query

  alias Rice.Repo
  alias Rice.Tsid
  alias Rice.SchemaTest.Widget

  setup do
    Repo.query!("""
    CREATE TABLE schema_test_widgets (
      id          tsid PRIMARY KEY,
      name        varchar(64) NOT NULL,
      legacy_id   varchar(36),
      parent_id   tsid REFERENCES schema_test_widgets(id),
      inserted_at timestamptz NOT NULL,
      updated_at  timestamptz NOT NULL
    )
    """)

    Repo.query!("""
    CREATE UNIQUE INDEX schema_test_widgets_legacy_idx
      ON schema_test_widgets (legacy_id) WHERE legacy_id IS NOT NULL
    """)

    :ok
  end

  test "tsid domain 就是 varchar(13)" do
    %{rows: [[type, len]]} =
      Repo.query!("""
      SELECT data_type, character_maximum_length
      FROM information_schema.columns
      WHERE table_name = 'schema_test_widgets' AND column_name = 'id'
      """)

    assert type == "character varying"
    assert len == 13
  end

  test "插入时自动生成 TSID 主键" do
    {:ok, widget} = %Widget{} |> Widget.changeset(%{name: "第一个"}) |> Repo.insert()

    assert Tsid.valid?(widget.id)
    assert widget.inserted_at
    assert widget.updated_at
  end

  test "按 id 排序等于按插入时间排序 —— keyset 分页的前提" do
    names = for i <- 1..50, do: "w#{i}"

    for name <- names do
      {:ok, _} = %Widget{} |> Widget.changeset(%{name: name}) |> Repo.insert()
    end

    ordered = Repo.all(from w in Widget, order_by: [asc: w.id], select: w.name)
    assert ordered == names

    by_time =
      Repo.all(from w in Widget, order_by: [asc: w.inserted_at, asc: w.id], select: w.name)

    assert by_time == names
  end

  test "keyset 分页:id > cursor 拿下一页" do
    for i <- 1..10 do
      {:ok, _} = %Widget{} |> Widget.changeset(%{name: "w#{i}"}) |> Repo.insert()
    end

    page1 = Repo.all(from w in Widget, order_by: [asc: w.id], limit: 4, select: w.name)
    assert page1 == ~w(w1 w2 w3 w4)

    cursor = Repo.one(from w in Widget, where: w.name == "w4", select: w.id)

    page2 =
      Repo.all(
        from w in Widget, where: w.id > ^cursor, order_by: [asc: w.id], limit: 4, select: w.name
      )

    assert page2 == ~w(w5 w6 w7 w8)
  end

  test "TSID 外键可用" do
    {:ok, parent} = %Widget{} |> Widget.changeset(%{name: "父"}) |> Repo.insert()

    {:ok, child} =
      %Widget{} |> Widget.changeset(%{name: "子", parent_id: parent.id}) |> Repo.insert()

    assert child.parent_id == parent.id
    assert Repo.preload(child, :parent).parent.name == "父"
  end

  test "指向不存在的父行会被外键约束挡下" do
    ghost = Tsid.generate()

    assert {:error, changeset} =
             %Widget{} |> Widget.changeset(%{name: "孤儿", parent_id: ghost}) |> Repo.insert()

    assert "does not exist" in errors_on(changeset).parent_id
  end

  test "非法的 TSID 在 changeset 阶段就被挡下,不会打到数据库" do
    for bad <- ["abc", "222222222222", "22222222222222", "222222222222!", "../../etc/passwd"] do
      changeset = Widget.changeset(%Widget{}, %{name: "x", parent_id: bad})
      refute changeset.valid?, "不该接受 parent_id = #{inspect(bad)}"
      assert "is invalid" in errors_on(changeset).parent_id
    end
  end

  # Ecto 的 cast/3 默认把 "" 当作"没填"(empty_values: [""]),在进类型之前就转成 nil,
  # 所以空串不会变成 :invalid 错误 —— 它等价于没传这个字段。记下来免得日后误判。
  test "空串被当作 nil,不是非法值" do
    changeset = Widget.changeset(%Widget{}, %{name: "x", parent_id: ""})
    assert changeset.valid?
    refute Map.has_key?(changeset.changes, :parent_id)
  end

  test "legacy_id 的 partial unique index:可以多行为 NULL,非 NULL 值唯一" do
    {:ok, _} = %Widget{} |> Widget.changeset(%{name: "a"}) |> Repo.insert()
    {:ok, _} = %Widget{} |> Widget.changeset(%{name: "b"}) |> Repo.insert()

    uuid = "3fa85f64-5717-4562-b3fc-2c963f66afa6"
    {:ok, _} = %Widget{} |> Widget.changeset(%{name: "c", legacy_id: uuid}) |> Repo.insert()

    assert {:error, changeset} =
             %Widget{} |> Widget.changeset(%{name: "d", legacy_id: uuid}) |> Repo.insert()

    assert "has already been taken" in errors_on(changeset).legacy_id
  end

  # 导入任务踩过的坑,留个回归测试。`on_conflict: :nothing` 在冲突时确实不会插入,
  # 但返回的结构里 id **依然有值** —— Ecto 只在主键由数据库生成时才把它置为 nil,
  # 而 TSID 是应用侧生成的。所以不能拿 `%{id: nil}` 判断"有没有真的插进去",
  # 只能靠插入前后各数一次。
  test "on_conflict: :nothing 冲突时不插入,但返回的 id 不是 nil" do
    uuid = "3fa85f64-5717-4562-b3fc-2c963f66afa6"
    {:ok, _} = %Widget{} |> Widget.changeset(%{name: "a", legacy_id: uuid}) |> Repo.insert()

    before_count = Repo.aggregate(Widget, :count)

    assert {:ok, returned} =
             %Widget{}
             |> Widget.changeset(%{name: "b", legacy_id: uuid})
             |> Repo.insert(on_conflict: :nothing)

    refute is_nil(returned.id), "返回的 id 若为 nil,导入任务的计数逻辑就可以简化"
    assert Repo.aggregate(Widget, :count) == before_count, "冲突行不该被插入"
  end

  test "并发插入不产生主键冲突" do
    parent_pid = self()

    ids =
      1..20
      |> Task.async_stream(
        fn i ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, parent_pid, self())
          {:ok, w} = %Widget{} |> Widget.changeset(%{name: "c#{i}"}) |> Repo.insert()
          w.id
        end,
        max_concurrency: 20
      )
      |> Enum.map(fn {:ok, id} -> id end)

    assert length(Enum.uniq(ids)) == 20
    assert Repo.aggregate(Widget, :count) == 20
  end
end
