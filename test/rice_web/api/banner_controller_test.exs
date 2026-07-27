defmodule RiceWeb.Api.BannerControllerTest do
  use RiceWeb.ConnCase, async: true

  describe "GET /api/banners" do
    test "空库返回空数组", %{conn: conn} do
      assert %{"data" => []} = conn |> get(~p"/api/banners") |> json_response(200)
    end

    test "按 position 升序", %{conn: conn} do
      banner_fixture(%{url: "c", position: 3})
      banner_fixture(%{url: "a", position: 1})
      banner_fixture(%{url: "b", position: 2})

      assert %{"data" => data} = conn |> get(~p"/api/banners") |> json_response(200)
      assert Enum.map(data, & &1["url"]) == ~w(a b c)
    end

    test "响应字段齐全", %{conn: conn} do
      image = attachment_fixture(%{filename: "banner.png", byte_size: 999})
      banner_fixture(%{url: "https://x.test", position: 4, image_id: image.id})

      assert %{"data" => [item]} = conn |> get(~p"/api/banners") |> json_response(200)

      assert %{
               "url" => "https://x.test",
               "position" => 4,
               "image" => %{"filename" => "banner.png", "byte_size" => 999, "url" => img_url}
             } = item

      assert img_url == "/api/attachments/#{image.id}"
    end

    test "链接可以为空 —— 线上确实有无跳转的 banner", %{conn: conn} do
      banner_fixture(%{url: ""})
      assert %{"data" => [%{"url" => ""}]} = conn |> get(~p"/api/banners") |> json_response(200)
    end
  end
end
