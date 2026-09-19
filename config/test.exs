import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :khymeia, Khymeia.Repo,
  database: Path.expand("../khymeia_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :khymeia, KhymeiaWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4778],
  secret_key_base: "gZN7fMRM+bon5kAKyp5tEvuxNA3bRDnpTY2YVLnn/tRlFI9nycI4hK4/Flybg5er",
  server: false

# Tests never depend on real harness CLIs.
config :khymeia,
  harness_adapters: [Khymeia.Harness.Fake],
  recover_sessions_on_boot: false,
  # Phoenix.ConnTest addresses requests to www.example.com.
  allowed_hosts: ["www.example.com"],
  workspace_roots: [Path.expand("../tmp/test-workspaces", __DIR__)]

config :khymeia, Khymeia.Harness.Fake, delay: "0.05"

# Never touch the developer's real Keychain from tests.
config :khymeia, secrets_backend: Khymeia.MemorySecrets

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
