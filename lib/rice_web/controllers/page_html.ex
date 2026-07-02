defmodule RiceWeb.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.

  See the `page_html` directory for all templates available.
  """
  use RiceWeb, :html

  embed_templates "page_html/*"

  @doc "Green/red verified pill for a boolean claim."
  def verified_badge(true) do
    Phoenix.HTML.raw(
      ~s(<span class="inline-block rounded-full bg-green-100 px-2 py-0.5 text-xs font-semibold text-green-700 dark:bg-green-900 dark:text-green-200">已验证</span>)
    )
  end

  def verified_badge(_) do
    Phoenix.HTML.raw(
      ~s(<span class="inline-block rounded-full bg-red-100 px-2 py-0.5 text-xs font-semibold text-red-700 dark:bg-red-900 dark:text-red-200">未验证</span>)
    )
  end

  @doc "Abbreviate an EVM address (0x1234…abcdef); em dash when absent."
  def short_wallet(addr) when is_binary(addr) and byte_size(addr) > 14 do
    String.slice(addr, 0, 8) <> "…" <> String.slice(addr, -6, 6)
  end

  def short_wallet(addr) when is_binary(addr), do: addr
  def short_wallet(_), do: "—"
end
