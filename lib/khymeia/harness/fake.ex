defmodule Khymeia.Harness.Fake do
  @moduledoc """
  A demo/test harness backed by `priv/bin/khymeia-fake-harness`.

  It is a real OS process driven through the same port and wrapper as Claude
  or Codex, so it exercises the whole runtime without any external CLI or
  credentials. The "model" selects the scenario:

    * `success` — a few messages, exit 0
    * `stream`  — twenty lines of streamed output, exit 0
    * `failure` — writes to stderr, exits with status 3
    * `hang`    — never finishes (use Stop, or a turn timeout)
    * workflow roles: `ask-advisor`, `ask-human` (implementer requests),
      `advise` (advisor), `audit-pass`, `audit-findings`, `audit-fix-once`
      (auditor verdicts; the last one passes from audit round 2)

  Enabled by default in dev and test. In releases set
  `KHYMEIA_ENABLE_FAKE_HARNESS=true` to enable it.
  """

  @behaviour Khymeia.Harness

  alias Khymeia.Harness.Capabilities

  @scenarios ~w(success stream failure hang ask-advisor ask-human advise audit-pass audit-findings audit-fix-once whoami)

  @impl true
  def id, do: :fake

  @impl true
  def name, do: "Fake harness"

  @impl true
  def detect do
    if File.regular?(script()),
      do: {:ok, %{executable: script(), version: "demo"}},
      else: :not_found
  end

  @impl true
  def capabilities do
    %Capabilities{
      streaming: true,
      structured_output: false,
      programmatic_mode: true,
      resume: true,
      stop: true,
      model_selection: true,
      models: @scenarios
    }
  end

  @impl true
  def provider_kinds, do: [:demo]

  @doc """
  Interactive mode, used to exercise the pseudo-terminal path in tests
  without any real agent CLI: it reports whether it is on a tty, echoes what
  is typed and exits on `exit`. A resume reference starting with `missing-`
  makes it refuse, the way a real harness does for a conversation it cannot
  find.
  """
  @impl true
  def build_interactive(session) do
    resume = if session.resume, do: ["--resume", session.resume], else: []
    args = ["--interactive"] ++ resume

    {:ok,
     %{
       executable: session.executable,
       args: args,
       env: [],
       harness_ref: session.resume || session.session_id
     }}
  end

  @impl true
  def build_command(turn) do
    scenario = if turn.model in @scenarios, do: turn.model, else: "success"
    delay = Application.get_env(:khymeia, __MODULE__, []) |> Keyword.get(:delay, "0.4")
    resume = if turn.resume, do: ["--resume", turn.resume], else: []

    args =
      [turn.executable, "--scenario", scenario, "--delay", delay] ++
        resume ++ ["--", turn.prompt]

    env =
      case turn[:provider] do
        nil ->
          []

        # Only presence is ever reported by the script, never the value.
        %{secret: %{access_key_id: id}} = p ->
          [{"FAKE_PROVIDER", p.name}, {"FAKE_PROVIDER_SECRET", id}]

        p ->
          [{"FAKE_PROVIDER", p.name}] ++
            if(p.secret, do: [{"FAKE_PROVIDER_SECRET", p.secret}], else: [])
      end

    {:ok, %{executable: "/bin/sh", args: args, env: env}}
  end

  @impl true
  def parse_output(:stderr, line), do: [{:stderr, line}]
  def parse_output(:stdout, "ref " <> ref), do: [{:harness_ref, ref}]
  def parse_output(:stdout, "say " <> text), do: [{:message, :assistant, text}]
  def parse_output(:stdout, "tool " <> text), do: [{:tool, "tool", text}]
  def parse_output(:stdout, line), do: [{:output, line}]

  defp script, do: Application.app_dir(:khymeia, "priv/bin/khymeia-fake-harness")
end
