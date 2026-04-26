import Config

config :ferri,
  env: :test
# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :ferri, Ferri.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "ferri_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :ferri, FerriWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "g2ngjn68fmHvoY0P4r8hkq1H6TFiKK7Y+PA02jVJE44mZxPwtdKsUStp52/k4xcP",
  server: false

# In test we don't send emails
config :ferri, Ferri.Mailer, adapter: Swoosh.Adapters.Test

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

# Bind listener sockets to OS-assigned ports in test so a running dev server
# on the production ports doesn't block `mix test`.
config :ferri, tcp_port: 0, http_port: 0
