defmodule Rice.Accounts do
  @moduledoc "Persistence for Semi↔PDS account links."
  alias Rice.Repo
  alias Rice.Accounts.SemiLink

  def get_link_by_sub(sub) when is_binary(sub) do
    Repo.get_by(SemiLink, semi_sub: sub)
  end

  def create_link(attrs) do
    %SemiLink{}
    |> SemiLink.changeset(attrs)
    |> Repo.insert()
  end
end
