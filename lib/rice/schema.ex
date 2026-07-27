defmodule Rice.Schema do
  @moduledoc """
  所有业务 schema 的公共前言。约定:

    * 主键是 `Rice.Tsid.Type`,自动生成(见 `Rice.Tsid`)
    * 外键同样是 TSID
    * 时间戳是 `inserted_at` / `updated_at`,`utc_datetime_usec`(Phoenix 惯例)

  用法:

      defmodule Rice.Accounts.User do
        use Rice.Schema

        schema "users" do
          field :handle, :string
          timestamps()
        end
      end
  """
  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema
      import Ecto.Changeset
      import Ecto.Query, only: [from: 2]

      @primary_key {:id, Rice.Tsid.Type, autogenerate: true}
      @foreign_key_type Rice.Tsid.Type
      @timestamps_opts [type: :utc_datetime_usec]
    end
  end
end
