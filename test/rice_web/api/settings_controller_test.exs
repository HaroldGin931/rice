defmodule RiceWeb.Api.SettingsControllerTest do
  use RiceWeb.ConnCase, async: true

  describe "GET /api/settings/foundation" do
    test "没有配置行时返回全零,不是 500 —— 全新部署也能跑", %{conn: conn} do
      assert %{"data" => data} =
               conn |> get(~p"/api/settings/foundation") |> json_response(200)

      assert data == %{
               "fund_scale" => 0,
               "issued_grain_scale" => 0,
               "proposal_approval_votes" => 0,
               "documents" => []
             }
    end

    test "返回配置值", %{conn: conn} do
      site_settings_fixture(%{
        fund_scale: 754_313,
        issued_grain_scale: 8_941_666,
        proposal_approval_votes: 20
      })

      assert %{"data" => data} =
               conn |> get(~p"/api/settings/foundation") |> json_response(200)

      assert data["fund_scale"] == 754_313
      assert data["issued_grain_scale"] == 8_941_666
      assert data["proposal_approval_votes"] == 20
    end

    test "公开文件按 position 排序", %{conn: conn} do
      site = site_settings_fixture()
      c = attachment_fixture(%{kind: "file", filename: "202603.pdf"})
      a = attachment_fixture(%{kind: "file", filename: "202601.pdf"})
      b = attachment_fixture(%{kind: "file", filename: "202602.pdf"})

      site_document_fixture(site, c, 3)
      site_document_fixture(site, a, 1)
      site_document_fixture(site, b, 2)

      assert %{"data" => %{"documents" => docs}} =
               conn |> get(~p"/api/settings/foundation") |> json_response(200)

      assert Enum.map(docs, & &1["filename"]) == ~w(202601.pdf 202602.pdf 202603.pdf)
    end
  end
end
