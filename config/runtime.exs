import Config

# Runtime configuration, read on every boot (including releases).
#
#   KHYMEIA_PORT                 HTTP port (default 4777)
#   KHYMEIA_BIND                 IP to bind (default 127.0.0.1). Anything but a
#                                loopback address exposes agent control to your
#                                network — see SECURITY in the README.
#   KHYMEIA_WORKSPACE_ROOTS      colon-separated directories sessions may run in
#                                (default: your home directory)
#   KHYMEIA_ENABLE_FAKE_HARNESS  "true" to offer the demo harness in releases
#   KHYMEIA_TURN_TIMEOUT_SECONDS kill a harness turn after N seconds (default: never)
#   KHYMEIA_DATA_DIR             database / secret location for releases
#   KHYMEIA_EXTRA_PATH           extra directories to search for harness CLIs
#   KHYMEIA_<ID>_BIN             pin a harness binary, e.g. KHYMEIA_CLAUDE_BIN

parse_ip = fn value ->
  case :inet.parse_address(String.to_charlist(value)) do
    {:ok, ip} -> ip
    {:error, _} -> raise "KHYMEIA_BIND is not a valid IP address: #{inspect(value)}"
  end
end

if config_env() != :test do
  port = String.to_integer(System.get_env("KHYMEIA_PORT") || System.get_env("PORT") || "4777")
  ip = parse_ip.(System.get_env("KHYMEIA_BIND", "127.0.0.1"))

  config :khymeia, KhymeiaWeb.Endpoint,
    http: [ip: ip, port: port],
    url: [host: "127.0.0.1", port: port]
end

# Lets several dev instances coexist (e.g. a preview next to your own server).
if config_env() == :dev and System.get_env("DATABASE_PATH") do
  config :khymeia, Khymeia.Repo, database: System.get_env("DATABASE_PATH")
end

if roots = System.get_env("KHYMEIA_WORKSPACE_ROOTS") do
  config :khymeia, workspace_roots: String.split(roots, ":", trim: true)
end

if timeout = System.get_env("KHYMEIA_TURN_TIMEOUT_SECONDS") do
  config :khymeia, turn_timeout: String.to_integer(timeout) * 1000
end

if System.get_env("KHYMEIA_ENABLE_FAKE_HARNESS") in ~w(true 1) do
  adapters = Application.get_env(:khymeia, :harness_adapters, [])
  config :khymeia, harness_adapters: Enum.uniq(adapters ++ [Khymeia.Harness.Fake])
end

# KHYMEIA_TIER_FAST=claude:sonnet, KHYMEIA_TIER_AUDIT=codex@azure-prod:my-deployment
# (harness[@provider profile name][:model])
tiers =
  for {"KHYMEIA_TIER_" <> name, value} <- System.get_env(), value != "", into: %{} do
    {harness, model} =
      case String.split(value, ":", parts: 2) do
        [harness, model] -> {harness, model}
        [harness] -> {harness, nil}
      end

    {harness, profile} =
      case String.split(harness, "@", parts: 2) do
        [harness, profile] -> {harness, profile}
        [harness] -> {harness, nil}
      end

    {name |> String.downcase() |> String.to_atom(),
     %{harness: String.to_atom(harness), model: model, profile: profile}}
  end

if tiers != %{} do
  config :khymeia,
    workflow_tiers: Map.merge(Application.get_env(:khymeia, :workflow_tiers, %{}), tiers)
end

if System.get_env("PHX_SERVER") do
  config :khymeia, KhymeiaWeb.Endpoint, server: true
end

if config_env() == :dev do
  config :khymeia, KhymeiaWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        ~r"lib/khymeia_web/router\.ex$"E,
        ~r"lib/khymeia_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  # A daemon must work with zero configuration, so data lives in a per-user
  # directory and the cookie-signing secret is generated once and kept there.
  data_dir =
    System.get_env("KHYMEIA_DATA_DIR") ||
      case :os.type() do
        {:unix, :darwin} ->
          Path.expand("~/Library/Application Support/Khymeia")

        _ ->
          Path.join(System.get_env("XDG_DATA_HOME") || Path.expand("~/.local/share"), "khymeia")
      end

  File.mkdir_p!(data_dir)
  File.chmod!(data_dir, 0o700)

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      (
        secret_file = Path.join(data_dir, "secret_key_base")

        case File.read(secret_file) do
          {:ok, secret} when byte_size(secret) >= 64 ->
            String.trim(secret)

          _ ->
            secret = :crypto.strong_rand_bytes(64) |> Base.encode64(padding: false)
            File.write!(secret_file, secret)
            File.chmod!(secret_file, 0o600)
            secret
        end
      )

  config :khymeia, Khymeia.Repo,
    database: System.get_env("DATABASE_PATH") || Path.join(data_dir, "khymeia.db"),
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  config :khymeia, KhymeiaWeb.Endpoint,
    server: true,
    secret_key_base: secret_key_base
end
