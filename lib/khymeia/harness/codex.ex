defmodule Khymeia.Harness.Codex do
  @moduledoc """
  Adapter for OpenAI Codex CLI (`codex`).

  Uses the documented non-interactive mode with JSONL events:

      codex exec --json [-m M] [-c sandbox_mode="S"] -- PROMPT
      codex exec resume --json [-m M] [-c sandbox_mode="S"] -- THREAD_ID PROMPT

  The workspace is passed as the process working directory (the `resume`
  subcommand has no `--cd` flag, so we use the cwd for both).

  Events read:

    * `thread.started` — `thread_id`, used to resume;
    * `item.started` / `item.completed` with item types `agent_message`,
      `reasoning`, `command_execution`, `file_change`, `mcp_tool_call`;
    * `turn.completed`, `turn.failed`, `error`.

  Unknown events are ignored.

  ## Limitations

    * `codex exec` refuses to run outside a Git repository unless
      `--skip-git-repo-check` is given. Khymeia does not pass it: that check
      is a Codex safety decision, and the error is surfaced as-is.
    * Codex cannot ask for approvals in `exec` mode; what it may do is decided
      by the sandbox mode. `danger-full-access` is intentionally not offered.
    * Models come from `codex debug models`, the CLI's own catalog. Only
      entries marked `"visibility": "list"` (the ones Codex shows in its own
      picker) are offered, ordered by Codex's `priority`. Because that command
      lives under `debug`, a failure to run or parse it just falls back to
      "default / type a model name". "Default" uses `~/.codex/config.toml`.
  """

  @behaviour Khymeia.Harness

  alias Khymeia.Harness.{Capabilities, Executable, Summary}

  @impl true
  def id, do: :codex

  @impl true
  def name, do: "Codex"

  @impl true
  def detect do
    case Executable.find(:codex, "codex") do
      {:ok, path} -> {:ok, %{executable: path, version: Executable.version(path)}}
      :not_found -> :not_found
    end
  end

  @impl true
  def capabilities do
    %Capabilities{
      streaming: true,
      structured_output: true,
      programmatic_mode: true,
      resume: true,
      stop: true,
      model_selection: true,
      models: :unknown,
      permission_modes: [
        {"read-only", "Sandbox: read-only"},
        {"workspace-write", "Sandbox: workspace-write"}
      ],
      read_only_mode: "read-only",
      read_only_enforcement: :sandbox,
      write_mode: "workspace-write"
    }
  end

  @impl true
  def list_models(executable) do
    with {:ok, json} <- Executable.run(executable, ["debug", "models"], timeout: 10_000) do
      parse_model_catalog(json)
    end
  end

  @doc false
  def parse_model_catalog(json) do
    with {:ok, %{"models" => models}} when is_list(models) <- Jason.decode(json) do
      models =
        models
        |> Enum.filter(&(is_map(&1) and &1["visibility"] == "list" and is_binary(&1["slug"])))
        |> Enum.sort_by(&(&1["priority"] || 1_000_000))
        |> Enum.map(fn m ->
          %{id: m["slug"], name: m["display_name"] || m["slug"], description: m["description"]}
        end)

      if models == [], do: :error, else: {:ok, models}
    else
      _ -> :error
    end
  end

  @impl true
  def provider_kinds, do: [:azure_openai, :bedrock]

  @impl true
  def build_command(turn) do
    {provider_args, env} = provider(turn[:provider])

    options =
      ["--json"] ++
        if(turn.model in [nil, ""], do: [], else: ["-m", turn.model]) ++
        sandbox(turn.permission_mode) ++ provider_args

    args =
      case turn.resume do
        nil -> ["exec"] ++ options ++ ["--", turn.prompt]
        ref -> ["exec", "resume"] ++ options ++ ["--", ref, turn.prompt]
      end

    {:ok, %{executable: turn.executable, args: args, env: env}}
  end

  @doc """
  The interactive TUI: `codex` with no subcommand, or `codex resume`.

  Unlike Claude Code, Codex does not accept a caller-chosen conversation id,
  so Khymeia cannot name the conversation up front. Resuming therefore uses
  the CLI's own `--last` (most recent session in this workspace) or an id the
  user picked; `harness_ref` stays empty until one is known.
  """
  @impl true
  def build_interactive(session) do
    {provider_args, env} = provider(session[:provider])

    options =
      if(session.model in [nil, ""], do: [], else: ["-m", session.model]) ++
        sandbox(session.permission_mode) ++ provider_args

    args =
      case session.resume do
        nil -> options
        "last" -> ["resume", "--last"] ++ options
        ref -> ["resume", ref] ++ options
      end

    {:ok, %{executable: session.executable, args: args, env: env}}
  end

  # Providers are configured with `-c` overrides, so the user's
  # ~/.codex/config.toml is never modified. Values were validated as plain
  # (no quotes or backslashes) before they get here.
  @azure_key_env "KHYMEIA_AZURE_OPENAI_API_KEY"

  defp provider(nil), do: {[], []}

  # Azure OpenAI / Foundry: the documented custom provider with the v1
  # Responses API. Codex reads the key from the variable named in env_key.
  defp provider(%{kind: :azure_openai, settings: s, secret: secret}) do
    args =
      config("model_provider", "khymeia_azure") ++
        config("model_providers.khymeia_azure.name", "Azure OpenAI (Khymeia)") ++
        config("model_providers.khymeia_azure.base_url", String.trim_trailing(s["base_url"], "/")) ++
        config("model_providers.khymeia_azure.env_key", @azure_key_env) ++
        config("model_providers.khymeia_azure.wire_api", "responses")

    {args, if(secret, do: [{@azure_key_env, secret}], else: [])}
  end

  # Amazon Bedrock: Codex's built-in `amazon-bedrock` provider, using the AWS
  # credential chain (profile) and region.
  # With access keys (from the Keychain) the SDK reads them from the
  # environment, so no profile is passed.
  defp provider(%{kind: :bedrock, settings: s, secret: secret}) do
    profile = if is_map(secret), do: nil, else: s["aws_profile"]

    args =
      config("model_provider", "amazon-bedrock") ++
        config("model_providers.amazon-bedrock.aws.region", s["region"]) ++
        if(profile, do: config("model_providers.amazon-bedrock.aws.profile", profile), else: [])

    {args, Khymeia.Harness.Claude.aws_credentials(secret, profile)}
  end

  defp config(key, value), do: ["-c", ~s(#{key}="#{value}")]

  defp sandbox(mode) when mode in ["read-only", "workspace-write"],
    do: ["-c", ~s(sandbox_mode="#{mode}")]

  defp sandbox(_), do: []

  @impl true
  def parse_output(:stderr, line), do: [{:stderr, line}]

  def parse_output(:stdout, line) do
    case Jason.decode(line) do
      {:ok, %{"type" => _} = event} -> parse_event(event)
      _ -> [{:output, line}]
    end
  end

  defp parse_event(%{"type" => "thread.started", "thread_id" => id}), do: [{:harness_ref, id}]

  defp parse_event(%{
         "type" => "item.started",
         "item" => %{"type" => "command_execution"} = item
       }),
       do: [{:tool, "shell", Summary.truncate(to_string(item["command"]))}]

  defp parse_event(%{"type" => "item.completed", "item" => item}), do: parse_item(item)

  defp parse_event(%{"type" => "turn.completed"} = event),
    do: [{:result, Map.take(event, ["usage"])}]

  defp parse_event(%{"type" => "turn.failed"} = event),
    do: [{:error, get_in(event, ["error", "message"]) || "turn failed"}]

  defp parse_event(%{"type" => "error"} = event), do: [{:error, event["message"] || "error"}]
  defp parse_event(_event), do: []

  defp parse_item(%{"type" => "error", "message" => message}), do: [{:error, message}]

  defp parse_item(%{"type" => "agent_message", "text" => text}),
    do: [{:message, :assistant, text}]

  defp parse_item(%{"type" => "reasoning", "text" => text}), do: [{:message, :reasoning, text}]

  defp parse_item(%{"type" => "command_execution"} = item) do
    [{:system, "#{Summary.truncate(to_string(item["command"]))} → exit #{item["exit_code"]}"}]
  end

  defp parse_item(%{"type" => "file_change", "changes" => changes}) when is_list(changes) do
    paths = Enum.map_join(changes, ", ", &"#{&1["kind"]} #{&1["path"]}")
    [{:tool, "edit", Summary.truncate(paths)}]
  end

  defp parse_item(%{"type" => "mcp_tool_call"} = item),
    do: [{:tool, "mcp", "#{item["server"]}.#{item["tool"]}"}]

  defp parse_item(_item), do: []
end
