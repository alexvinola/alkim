defmodule Alkim.Harness.Claude do
  @moduledoc """
  Adapter for Claude Code (`claude`).

  Uses the documented non-interactive mode:

      claude -p --output-format stream-json --verbose [--model M]
             [--permission-mode P] [--resume ID] -- PROMPT

  `stream-json` emits one JSON object per line. We read:

    * `{"type":"system","subtype":"init","session_id":...}` — the conversation
      id, later used with `--resume` for follow-up messages;
    * `{"type":"assistant","message":{"content":[...]}}` — text, thinking
      and tool_use blocks;
    * `{"type":"result",...}` — the turn summary.

  Anything else is ignored rather than guessed at.

  ## Limitations

    * In `-p` mode Claude Code cannot ask for permission interactively. Tools
      that need approval are denied unless a permission mode (or the user's
      Claude settings) allows them. `bypassPermissions` is intentionally not
      offered from the UI.
    * Claude Code has no command to list models. What the installed CLI does
      document is its model *aliases*, in the `--model` entry of
      `claude --help` ("an alias for the latest model (e.g. 'fable', ...)").
      Those aliases are read from the help text, so they follow the installed
      version instead of being hard-coded here; a full model name can still be
      typed. If the help text changes shape, the list is simply empty.
  """

  @behaviour Alkim.Harness

  alias Alkim.Harness.{Capabilities, Executable, Summary}

  @impl true
  def id, do: :claude

  @impl true
  def name, do: "Claude Code"

  @impl true
  def detect do
    case Executable.find(:claude, "claude") do
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
        {"plan", "Plan only (read-only)"},
        {"acceptEdits", "Accept edits"},
        {"auto", "Auto"},
        {"dontAsk", "Don't ask (deny unapproved tools)"}
      ],
      # Plan mode is Claude Code's own read-only mode: enforced by the CLI's
      # permission system, not by an OS sandbox.
      read_only_mode: "plan",
      read_only_enforcement: :harness,
      write_mode: "acceptEdits"
    }
  end

  @impl true
  def list_models(executable) do
    with {:ok, help} <- Executable.run(executable, ["--help"]) do
      parse_model_aliases(help)
    end
  end

  @doc false
  # Extracts the aliases from the `--model` entry of `claude --help`, whose
  # description reads "Provide an alias for the latest model (e.g. 'a', 'b',
  # or 'c') or a model's full name (e.g. '...')". Only the first parenthesis —
  # the alias examples — is used.
  def parse_model_aliases(help) do
    text = String.replace(help, ~r/\s+/, " ")

    with [_, entry] <- Regex.run(~r/--model <model> (.*?)(?: --[a-z]|$)/, text),
         [_, aliases] <- Regex.run(~r/alias[^(]*\(e\.g\. ([^)]*)\)/, entry),
         [_ | _] = names <- Regex.scan(~r/'([A-Za-z0-9][A-Za-z0-9._-]*)'/, aliases) do
      {:ok,
       for [_, name] <- names do
         %{id: name, name: name, description: "Alias for the latest #{name} model"}
       end}
    else
      _ -> :error
    end
  end

  @impl true
  def provider_kinds, do: [:bedrock, :foundry, :vertex]

  @impl true
  def build_command(turn) do
    # Alkim names the conversation on the first turn, so the same one can
    # later be opened in the real CLI (`--resume <id>`) without having to
    # learn an id the harness chose. Verified with Claude Code 2.1.212:
    # `-p --session-id <uuid>` writes `<uuid>.jsonl`.
    identity =
      case {turn.resume, turn[:session_id]} do
        {nil, id} when is_binary(id) -> ["--session-id", id]
        {ref, _} when is_binary(ref) -> ["--resume", ref]
        _ -> []
      end

    args =
      ["-p", "--output-format", "stream-json", "--verbose"] ++
        opt("--model", turn.model) ++
        opt("--permission-mode", turn.permission_mode) ++
        identity ++
        ["--", turn.prompt]

    {:ok, %{executable: turn.executable, args: args, env: env(turn[:provider])}}
  end

  @doc """
  The interactive TUI.

  Claude Code accepts `--session-id <uuid>`, so Alkim names the
  conversation before it exists and can resume exactly that one later.
  `--no-session-persistence` only works with `--print`, so an interactive
  conversation is always saved to disk and always resumable.
  """
  @impl true
  def build_interactive(session) do
    {args, ref} =
      case session.resume do
        nil -> {["--session-id", session.session_id], session.session_id}
        ref -> {["--resume", ref], ref}
      end

    args =
      args ++
        opt("--model", session.model) ++
        opt("--permission-mode", session.permission_mode)

    {:ok,
     %{executable: session.executable, args: args, env: env(session[:provider]), harness_ref: ref}}
  end

  @doc """
  `/exit`, verified against Claude Code 2.1.212: it quits and the
  conversation is written to `~/.claude/projects/…`, where `--resume` finds
  it. Ending the process with a signal instead loses it.
  """
  @impl true
  def quit_sequence, do: "/exit\r"

  # Claude Code exports a whole family of CLAUDE_* variables to its own
  # subprocesses — session ids, a messaging socket, "child session" markers.
  # Alkim is often started from one of its terminals, so every one of them
  # is cleared: a session it starts must not look like a continuation of the
  # session that happened to launch Alkim.
  defp env(provider) do
    provider = provider_env(provider)
    Alkim.Harness.clear_inherited(["CLAUDE"], provider) ++ provider
  end

  # Documented in Claude Code's "Amazon Bedrock", "Microsoft Foundry" and
  # "Google Vertex AI" guides. The other providers' switches are unset so an
  # inherited variable can never route a profile to the wrong cloud.
  @switches ~w(CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_MANTLE CLAUDE_CODE_USE_FOUNDRY CLAUDE_CODE_USE_VERTEX)

  defp provider_env(nil), do: []

  defp provider_env(%{kind: kind, settings: s, secret: secret}) do
    {switch, vars} =
      case kind do
        :bedrock ->
          {"CLAUDE_CODE_USE_BEDROCK",
           [{"AWS_REGION", s["region"]}, {"ANTHROPIC_BEDROCK_BASE_URL", s["base_url"]}] ++
             aws_credentials(secret, s["aws_profile"])}

        :foundry ->
          {"CLAUDE_CODE_USE_FOUNDRY",
           [
             {"ANTHROPIC_FOUNDRY_RESOURCE", s["resource"]},
             {"ANTHROPIC_FOUNDRY_BASE_URL", s["base_url"]},
             # Without a key Claude Code uses the Azure default credential chain.
             {"ANTHROPIC_FOUNDRY_API_KEY", secret}
           ]}

        :vertex ->
          {"CLAUDE_CODE_USE_VERTEX",
           [
             {"ANTHROPIC_VERTEX_PROJECT_ID", s["project_id"]},
             {"CLOUD_ML_REGION", s["region"]},
             {"GOOGLE_APPLICATION_CREDENTIALS", s["credentials_file"]}
           ]}
      end

    Enum.map(@switches -- [switch], &{&1, false}) ++
      [{switch, "1"}] ++ for({k, v} <- vars, v != nil and v != "", do: {k, v})
  end

  @doc false
  # AWS credentials for a profile, shared with the Codex adapter. Explicit
  # credentials always clear the others: inherited AWS_* variables would
  # otherwise silently win over the chosen profile (the SDK checks the
  # environment first) and route the session to a different account.
  def aws_credentials(
        %{access_key_id: id, secret_access_key: key, session_token: token},
        _profile
      ) do
    [
      {"AWS_ACCESS_KEY_ID", id},
      {"AWS_SECRET_ACCESS_KEY", key},
      {"AWS_SESSION_TOKEN", token || false},
      {"AWS_PROFILE", false},
      {"AWS_BEARER_TOKEN_BEDROCK", false}
    ]
  end

  def aws_credentials(bearer, _profile) when is_binary(bearer),
    do: [{"AWS_BEARER_TOKEN_BEDROCK", bearer} | clear_aws_keys()]

  def aws_credentials(nil, profile) when is_binary(profile),
    do: [{"AWS_PROFILE", profile}, {"AWS_BEARER_TOKEN_BEDROCK", false} | clear_aws_keys()]

  # Ambient without a named profile: whatever the environment provides.
  def aws_credentials(nil, nil), do: []

  defp clear_aws_keys,
    do: [
      {"AWS_ACCESS_KEY_ID", false},
      {"AWS_SECRET_ACCESS_KEY", false},
      {"AWS_SESSION_TOKEN", false}
    ]

  @impl true
  def parse_output(:stderr, line), do: [{:stderr, line}]

  def parse_output(:stdout, line) do
    case Jason.decode(line) do
      {:ok, %{"type" => _} = event} -> parse_event(event)
      _ -> [{:output, line}]
    end
  end

  defp parse_event(%{"type" => "system", "subtype" => "init"} = event) do
    ref = if id = event["session_id"], do: [{:harness_ref, id}], else: []
    model = if model = event["model"], do: [{:system, "model #{model}"}], else: []
    ref ++ model
  end

  # Retries are how a misconfigured provider (wrong resource, region,
  # credentials) shows up, so they are surfaced instead of ignored.
  defp parse_event(%{"type" => "system", "subtype" => "api_retry"} = event) do
    status = if event["error_status"], do: "HTTP #{event["error_status"]}, ", else: ""

    [
      {:system,
       "API retry #{event["attempt"]}/#{event["max_retries"]} (#{status}#{event["error"] || "error"})"}
    ]
  end

  defp parse_event(%{"type" => "assistant", "message" => %{"content" => content}})
       when is_list(content) do
    Enum.flat_map(content, fn
      %{"type" => "text", "text" => text} ->
        [{:message, :assistant, text}]

      %{"type" => "thinking", "thinking" => text} when text != "" ->
        [{:message, :reasoning, text}]

      # In plan mode the answer can arrive as the plan of ExitPlanMode.
      %{"type" => "tool_use", "name" => "ExitPlanMode", "input" => %{"plan" => plan}}
      when is_binary(plan) ->
        [{:message, :assistant, plan}]

      %{"type" => "tool_use", "name" => name} = block ->
        [{:tool, name, Summary.input(block["input"])}]

      _ ->
        []
    end)
  end

  defp parse_event(%{"type" => "result"} = event) do
    summary =
      Map.take(event, ["subtype", "is_error", "duration_ms", "num_turns", "total_cost_usd"])

    error =
      if event["is_error"] == true,
        do: [{:error, event["result"] || event["subtype"] || "error"}],
        else: []

    error ++ [{:result, summary}]
  end

  defp parse_event(_event), do: []

  defp opt(_flag, nil), do: []
  defp opt(_flag, ""), do: []
  defp opt(flag, value), do: [flag, value]
end
