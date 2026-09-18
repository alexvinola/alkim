# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :khymeia,
  ecto_repos: [Khymeia.Repo],
  generators: [timestamp_type: :utc_datetime]

# Runtime defaults (see config/runtime.exs for the environment variables).
config :khymeia,
  harness_adapters: [Khymeia.Harness.Claude, Khymeia.Harness.Codex],
  # Maximum wall time of one harness turn; :infinity lets agents work.
  turn_timeout: :infinity,
  # How long a finished session process keeps its activity log in memory.
  session_retention_ms: :timer.minutes(30),
  max_sessions: 32,
  max_workflows: 8,
  # Capability tiers: default harness/model per kind of role. Models are left
  # to each harness (nil) unless you set one. Override per tier with
  # KHYMEIA_TIER_<NAME>=harness[:model].
  workflow_tiers: %{
    fast: %{harness: :claude, model: nil},
    reasoning: %{harness: :claude, model: nil},
    audit: %{harness: :codex, model: nil}
  }

# Configure the endpoint
config :khymeia, KhymeiaWeb.Endpoint,
  url: [host: "127.0.0.1"],
  # Only pages served by Khymeia itself may open LiveView sockets.
  check_origin: ["//127.0.0.1", "//localhost", "//[::1]"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: KhymeiaWeb.ErrorHTML, json: KhymeiaWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Khymeia.PubSub,
  live_view: [signing_salt: "6RNxt5kW"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  khymeia: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  khymeia: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
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
