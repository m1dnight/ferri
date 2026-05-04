# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :ferri,
  ecto_repos: [Ferri.Repo],
  generators: [timestamp_type: :utc_datetime],
  tcp_port: 59595,
  http_port: 8080,
  # Per-session rate limit on data flowing Ferri -> visitors. This caps the
  # total throughput a client can send to all visitors combined. holds up to
  # `tunnel_burst_bytes` and refills at `tunnel_rate_bps` bytes/sec. Default is
  # 1 MB/s sustained with a 1 MB burst.
  tunnel_rate_bps: 1_048_576,
  tunnel_burst_bytes: 1_048_576

# Configure the endpoint
config :ferri, FerriWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: FerriWeb.ErrorHTML, json: FerriWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Ferri.PubSub,
  live_view: [signing_salt: "UR8ymsDx"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :ferri, Ferri.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  ferri: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  ferri: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
