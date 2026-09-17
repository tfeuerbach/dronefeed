import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :drone_feed, DroneFeed.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: String.to_integer(System.get_env("PGPORT", "5434")),
  database: "drone_feed_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :drone_feed, DroneFeed.Mailer, adapter: Swoosh.Adapters.Test
config :swoosh, :api_client, false

config :drone_feed,
  storage_root: Path.expand("../tmp/test_storage", __DIR__),
  ffmpeg_path: "echo",
  publisher_enabled: false,
  restore_publishers_on_boot: false,
  mediamtx_api_enabled: false,
  udp_ingest_port_min: 8900,
  udp_ingest_port_max: 8905

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :drone_feed, DroneFeedWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "3lRJFcR7kdw8GPtIC+r7cWKA+t+rBwr6jtfx719ezKrqFyqrxn+VHYL8ZlGRJSRH",
  server: false

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
