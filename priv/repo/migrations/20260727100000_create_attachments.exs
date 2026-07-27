defmodule Rice.Repo.Migrations.CreateAttachments do
  use Ecto.Migration
  import Rice.Migration

  # core 把文件类型、GUID 和用户提供的原始文件名拼成一个字符串当 fileId:
  #
  #     1-b656bee82c934e70b4831a75a5abcfdc-GU logo 1-512.jpg
  #     └ 类型  └ GUID(N 格式)              └ 用户提供的文件名(含中文/空格/括号)
  #
  # 落盘路径直接用它拼,用户文件名进路径是现成的路径穿越面。新表里落盘路径只由
  # TSID 决定(storage_key),原始文件名只在下载时的 Content-Disposition 里出现。
  #
  # byte_size / checksum / storage_key 现在可空:期 1 只导元数据,真正把文件从 core
  # 的容器里搬过来是期 2 的事,搬完再收紧成 NOT NULL。
  def change do
    create table(:attachments, primary_key: false) do
      tsid_primary_key()
      add :legacy_id, :string, size: 200
      add :kind, :string, size: 16, null: false
      add :filename, :string, size: 255, null: false
      add :content_type, :string, size: 128
      add :byte_size, :bigint
      add :checksum, :string, size: 64
      add :storage_key, :string, size: 256

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:attachments, [:legacy_id], where: "legacy_id is not null")
    create constraint(:attachments, :attachments_kind, check: "kind in ('image', 'file')")
  end
end
