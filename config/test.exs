import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :rice, Rice.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "rice_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :rice, RiceWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "m2OUuTMsfbDK+sXBVLrGLHN32ya2ILNcYkuHYaxhOMjEhdbiH/ginZoOWFhIgx6Z",
  server: false

# 外部依赖全部走 Mox 打桩:测试不碰磁盘、不打 PDS、不发短信
config :rice, :pds_client, Rice.PDSMock
config :rice, :notifications, Rice.NotificationsMock

# 附件走 Mox 打桩,测试不碰磁盘
config :rice, :storage, Rice.Files.StorageMock
config :rice, :storage_root, Path.expand("../tmp/test_storage", __DIR__)

# 测试里任务不自动跑,由测试用 Oban.drain_queue/1 显式驱动
config :rice, Oban, testing: :manual

# In test we don't send emails
config :rice, Rice.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
