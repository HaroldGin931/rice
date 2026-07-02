defmodule Rice.Repo.Migrations.CreateSemiLinks do
  use Ecto.Migration

  def change do
    create table(:semi_links) do
      # Semi's stable subject identifier (OIDC `sub`) — one PDS account per sub.
      add :semi_sub, :string, null: false
      # The AT Protocol account rice provisioned/linked for this Semi user.
      add :did, :string, null: false
      add :handle, :string, null: false
      # The account password rice generated, encrypted at rest (AES-256-GCM).
      # rice re-uses it to createSession on return visits.
      add :account_password_ciphertext, :binary, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:semi_links, [:semi_sub])
    create unique_index(:semi_links, [:did])
  end
end
