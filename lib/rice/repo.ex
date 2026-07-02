defmodule Rice.Repo do
  use Ecto.Repo,
    otp_app: :rice,
    adapter: Ecto.Adapters.Postgres
end
