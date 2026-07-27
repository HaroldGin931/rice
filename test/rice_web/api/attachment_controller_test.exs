defmodule RiceWeb.Api.AttachmentControllerTest do
  use RiceWeb.ConnCase, async: true

  import Mox

  setup :verify_on_exit!

  defp write_tmp(content) do
    path = Path.join(System.tmp_dir!(), "upload_#{System.unique_integer([:positive])}")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp stored_fixture(attrs \\ %{}) do
    attachment = attachment_fixture(attrs)

    {:ok, updated} =
      Rice.Repo.update(
        Ecto.Changeset.change(attachment, storage_key: Rice.Files.storage_key(attachment.id))
      )

    updated
  end

  describe "GET /api/attachments/:id" do
    test "返回字节和正确的 content-type", %{conn: conn} do
      attachment = stored_fixture(%{content_type: "image/png", filename: "banner.png"})
      expect(Rice.Files.StorageMock, :get, fn _ -> {:ok, "PNGDATA"} end)

      conn = get(conn, ~p"/api/attachments/#{attachment.id}")

      assert response(conn, 200) == "PNGDATA"
      assert get_resp_header(conn, "content-type") == ["image/png"]
    end

    test "没有 content_type 时退回 octet-stream", %{conn: conn} do
      attachment = stored_fixture(%{content_type: nil})
      expect(Rice.Files.StorageMock, :get, fn _ -> {:ok, "x"} end)

      conn = get(conn, ~p"/api/attachments/#{attachment.id}")
      assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
    end

    test "默认内联展示", %{conn: conn} do
      attachment = stored_fixture(%{filename: "a.png"})
      expect(Rice.Files.StorageMock, :get, fn _ -> {:ok, "x"} end)

      conn = get(conn, ~p"/api/attachments/#{attachment.id}")
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "inline"
    end

    test "?download=1 时强制下载", %{conn: conn} do
      attachment = stored_fixture(%{filename: "a.pdf"})
      expect(Rice.Files.StorageMock, :get, fn _ -> {:ok, "x"} end)

      conn = get(conn, ~p"/api/attachments/#{attachment.id}?download=1")
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
    end

    # 线上文件名带中文、空格和全角括号。不编码的话这些字节会直接进响应头 ——
    # 轻则被客户端截断,重则被用来注入额外的头。
    test "中文/空格/括号文件名被正确编码", %{conn: conn} do
      name = "乡建DAO-截至20250831 财务收支 （公示）.pdf"
      attachment = stored_fixture(%{filename: name, kind: "file"})
      expect(Rice.Files.StorageMock, :get, fn _ -> {:ok, "x"} end)

      conn = get(conn, ~p"/api/attachments/#{attachment.id}")
      assert [disposition] = get_resp_header(conn, "content-disposition")

      assert disposition =~ "filename*=UTF-8''"
      refute disposition =~ name
      refute disposition =~ "\r"
      refute disposition =~ "\n"
      assert disposition |> String.split("''") |> List.last() |> URI.decode() == name
    end

    test "换行不会漏进响应头", %{conn: conn} do
      attachment = stored_fixture(%{filename: "a\r\nX-Injected: yes.png"})
      expect(Rice.Files.StorageMock, :get, fn _ -> {:ok, "x"} end)

      conn = get(conn, ~p"/api/attachments/#{attachment.id}")

      assert get_resp_header(conn, "x-injected") == []
      assert [disposition] = get_resp_header(conn, "content-disposition")
      refute disposition =~ "\n"
    end

    test "带不可变缓存头和 etag", %{conn: conn} do
      attachment = stored_fixture(%{checksum: String.duplicate("a", 64)})
      expect(Rice.Files.StorageMock, :get, fn _ -> {:ok, "x"} end)

      conn = get(conn, ~p"/api/attachments/#{attachment.id}")

      assert ["public, max-age=31536000, immutable"] = get_resp_header(conn, "cache-control")
      assert [~s("#{String.duplicate("a", 64)}")] == get_resp_header(conn, "etag")
    end

    test "不存在的 id 返回 404", %{conn: conn} do
      assert conn
             |> get(~p"/api/attachments/#{Rice.Tsid.generate()}")
             |> json_response(404)
    end

    test "格式非法的 id 返回 404 而不是 500", %{conn: conn} do
      for bad <- ["abc", "222222222222", "../../etc/passwd", "222222222222!"] do
        assert conn |> get(~p"/api/attachments/#{bad}") |> json_response(404)
      end
    end

    # 期 2 只回填,元数据先于字节存在。这段时间读到的应该是 404,不是 500。
    test "元数据在但字节还没回填,返回 404", %{conn: conn} do
      attachment = attachment_fixture()
      assert conn |> get(~p"/api/attachments/#{attachment.id}") |> json_response(404)
    end

    test "文件在库里有记录但磁盘上丢了,也是 404", %{conn: conn} do
      attachment = stored_fixture()
      expect(Rice.Files.StorageMock, :get, fn _ -> {:error, :enoent} end)

      assert conn |> get(~p"/api/attachments/#{attachment.id}") |> json_response(404)
    end
  end

  describe "POST /api/attachments 的认证" do
    # core 的 /api/v1/file/upload 是 AllowAnonymous —— 任何人都能往服务器写文件。
    # 这条防线要一直立着。
    test "未认证时 401,不是 404 也不是 201", %{conn: conn} do
      assert conn |> post(~p"/api/attachments", %{}) |> json_response(401)
    end

    test "伪造 / 过期的令牌同样 401", %{conn: conn} do
      for bad <- ["", "abc", String.duplicate("a", 43)] do
        assert conn
               |> put_req_header("authorization", "Bearer " <> bad)
               |> post(~p"/api/attachments", %{})
               |> json_response(401)
      end
    end

    # 扫路由表 + 实打一遍。断言行为而不是结构:任何写附件的路由,
    # 未认证时都必须是 401。将来新增上传相关路由也会被这条覆盖到。
    test "登录后可以上传", %{conn: conn} do
      {_user, token} = user_with_token()
      expect(Rice.Files.StorageMock, :put, fn _key, "PNGDATA" -> :ok end)

      upload = %Plug.Upload{
        path: write_tmp("PNGDATA"),
        filename: "a.png",
        content_type: "image/png"
      }

      assert %{"data" => data} =
               conn
               |> authed(token)
               |> post(~p"/api/attachments", %{file: upload})
               |> json_response(201)

      assert data["kind"] == "image"
      assert data["filename"] == "a.png"
      assert data["byte_size"] == 7
      assert data["url"] == "/api/attachments/#{data["id"]}"
    end

    # 客户端可以在 filename 里塞任意内容,包括路径
    test "上传的 filename 里的路径被剥掉", %{conn: conn} do
      {_user, token} = user_with_token()
      expect(Rice.Files.StorageMock, :put, fn _key, _ -> :ok end)

      upload = %Plug.Upload{
        path: write_tmp("x"),
        filename: "../../../etc/passwd.png",
        content_type: "image/png"
      }

      assert %{"data" => %{"filename" => "passwd.png"}} =
               conn
               |> authed(token)
               |> post(~p"/api/attachments", %{file: upload})
               |> json_response(201)
    end

    test "白名单外的类型 422", %{conn: conn} do
      {_user, token} = user_with_token()

      upload = %Plug.Upload{
        path: write_tmp("#!/bin/sh"),
        filename: "x.sh",
        content_type: "application/x-sh"
      }

      assert conn
             |> authed(token)
             |> post(~p"/api/attachments", %{file: upload})
             |> json_response(422)
    end

    test "缺文件 422", %{conn: conn} do
      {_user, token} = user_with_token()
      assert conn |> authed(token) |> post(~p"/api/attachments", %{}) |> json_response(422)
    end

    test "上传的文件可以立刻读回来", %{conn: conn} do
      {_user, token} = user_with_token()
      expect(Rice.Files.StorageMock, :put, fn _key, "DATA" -> :ok end)

      upload = %Plug.Upload{path: write_tmp("DATA"), filename: "a.png", content_type: "image/png"}

      id =
        conn
        |> authed(token)
        |> post(~p"/api/attachments", %{file: upload})
        |> json_response(201)
        |> get_in(["data", "id"])

      expect(Rice.Files.StorageMock, :get, fn _ -> {:ok, "DATA"} end)
      assert build_conn() |> get(~p"/api/attachments/#{id}") |> response(200) == "DATA"
    end

    test "所有写附件的路由未认证时都返回 401", %{conn: conn} do
      writes =
        RiceWeb.Router.__routes__()
        |> Enum.filter(&(&1.verb in [:post, :put, :patch, :delete]))
        |> Enum.filter(&String.starts_with?(&1.path, "/api/attachments"))

      assert writes != [], "上传路由不见了"

      for route <- writes do
        path = String.replace(route.path, ~r/:\w+/, Rice.Tsid.generate())

        status =
          conn
          |> Phoenix.ConnTest.dispatch(@endpoint, route.verb, path, %{})
          |> Map.fetch!(:status)

        assert status == 401, "#{route.verb} #{route.path} 未认证时返回了 #{status}"
      end
    end
  end
end
