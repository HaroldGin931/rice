defmodule Rice.Import.AttachmentsTest do
  @moduledoc "回填要真的读磁盘,所以用临时目录 + 真实的本机存储实现。"
  use Rice.DataCase, async: false

  alias Rice.Import.Attachments

  setup do
    source = Path.join(System.tmp_dir!(), "core_data_#{System.unique_integer([:positive])}")
    dest = Path.join(System.tmp_dir!(), "rice_store_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(source, "Picture"))
    File.mkdir_p!(Path.join(source, "File"))
    File.mkdir_p!(dest)

    prev_storage = Application.get_env(:rice, :storage)
    prev_root = Application.get_env(:rice, :storage_root)
    Application.put_env(:rice, :storage, Rice.Files.Storage.Local)
    Application.put_env(:rice, :storage_root, dest)

    on_exit(fn ->
      File.rm_rf!(source)
      File.rm_rf!(dest)
      Application.put_env(:rice, :storage, prev_storage)
      Application.put_env(:rice, :storage_root, prev_root)
    end)

    %{source: source, dest: dest}
  end

  defp seed(source, kind, guid, filename, content) do
    subdir = if kind == "image", do: "Picture", else: "File"
    File.write!(Path.join([source, subdir, "#{guid}-#{filename}"]), content)
    code = if kind == "image", do: "1", else: "2"

    # 与真实的期 1 导入结果一致:只有元数据,字节相关的列全是 NULL
    attachment_fixture(%{
      kind: kind,
      filename: filename,
      legacy_id: "#{code}-#{guid}-#{filename}",
      content_type: nil,
      byte_size: nil
    })
  end

  test "把文件搬过来并补齐元数据", %{source: source} do
    attachment = seed(source, "image", "abc123", "banner.png", "PNGBYTES")

    assert %{copied: 1, missing: [], failed: []} = Attachments.run(source, true)

    reloaded = Rice.Repo.get!(Rice.Files.Attachment, attachment.id)
    assert reloaded.byte_size == 8
    assert reloaded.content_type == "image/png"
    assert reloaded.storage_key == Rice.Files.storage_key(attachment.id)

    assert reloaded.checksum ==
             :crypto.hash(:sha256, "PNGBYTES") |> Base.encode16(case: :lower)

    assert {:ok, "PNGBYTES"} = Rice.Files.read(reloaded)
  end

  test "落盘路径只由 TSID 决定,原始文件名不进路径", %{source: source, dest: dest} do
    attachment = seed(source, "file", "g1", "乡建DAO-截至20250831 财务收支 （公示）.pdf", "PDF")

    assert %{copied: 1} = Attachments.run(source, true)

    files = Path.wildcard(Path.join(dest, "**/*")) |> Enum.filter(&File.regular?/1)
    assert [path] = files
    assert Path.basename(path) == attachment.id
    refute path =~ "乡建"
    refute path =~ " "
  end

  test "含连字符和中文的文件名能在源目录里找到", %{source: source} do
    seed(source, "image", "b656bee8", "GU logo 1-512.jpg", "JPEG")
    seed(source, "file", "408513fe", "乡建DAO-截至20250831 财务收支 （公示）.pdf", "PDF")

    assert %{copied: 2, missing: [], failed: []} = Attachments.run(source, true)
  end

  test "按扩展名推断 content type", %{source: source} do
    seed(source, "image", "g1", "a.png", "x")
    seed(source, "image", "g2", "b.JPG", "x")
    seed(source, "file", "g3", "c.pdf", "x")
    seed(source, "file", "g4", "d.html", "x")
    seed(source, "file", "g5", "e.unknown", "x")

    Attachments.run(source, true)

    types =
      Rice.Repo.all(Rice.Files.Attachment)
      |> Map.new(&{&1.filename, &1.content_type})

    assert types["a.png"] == "image/png"
    assert types["b.JPG"] == "image/jpeg"
    assert types["c.pdf"] == "application/pdf"
    assert types["d.html"] == "text/html"
    assert types["e.unknown"] == "application/octet-stream"
  end

  test "源文件缺失时记进 missing,不是崩溃", %{source: source} do
    attachment_fixture(%{kind: "image", filename: "gone.png", legacy_id: "1-nope-gone.png"})

    assert %{copied: 0, missing: ["1-nope-gone.png"], failed: []} = Attachments.run(source, true)
  end

  test "dry-run 不写任何东西", %{source: source, dest: dest} do
    attachment = seed(source, "image", "abc", "a.png", "DATA")

    assert %{copied: 1, failed: []} = Attachments.run(source, false)

    reloaded = Rice.Repo.get!(Rice.Files.Attachment, attachment.id)
    assert is_nil(reloaded.storage_key)
    assert is_nil(reloaded.byte_size)
    assert Path.wildcard(Path.join(dest, "**/*")) |> Enum.filter(&File.regular?/1) == []
  end

  test "幂等:第二次跑没有待办", %{source: source} do
    seed(source, "image", "abc", "a.png", "DATA")

    assert %{copied: 1} = Attachments.run(source, true)
    assert %{copied: 0, missing: [], failed: []} = Attachments.run(source, true)
  end

  test "二进制内容原样搬运,校验和对得上", %{source: source} do
    content = :crypto.strong_rand_bytes(64 * 1024)
    attachment = seed(source, "image", "bin", "big.png", content)

    assert %{copied: 1} = Attachments.run(source, true)

    reloaded = Rice.Repo.get!(Rice.Files.Attachment, attachment.id)
    assert {:ok, ^content} = Rice.Files.read(reloaded)
    assert reloaded.checksum == :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
    assert reloaded.byte_size == byte_size(content)
  end
end
