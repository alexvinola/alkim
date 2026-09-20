# Khymeia

[![CI](https://github.com/alexvinola/khymeia/actions/workflows/ci.yml/badge.svg)](https://github.com/alexvinola/khymeia/actions/workflows/ci.yml)

**A local-first runtime to supervise, coordinate and verify the coding-agent
harnesses you already have installed** — Claude Code and Codex today, with
Kiro CLI, GitHub Copilot CLI, OpenCode and Gemini CLI detected and planned.

Khymeia runs as a long-lived local daemon. Every agent session is a supervised
OTP process driving the real CLI; its output streams as events into a Phoenix
LiveView UI at <http://127.0.0.1:4777>. On top of single sessions,
**workflows** put several harnesses to work in roles — an *implementer* that
writes code, an *advisor* it can consult, an independent read-only *auditor*
whose findings loop back — with a human able to step in at any checkpoint.

Khymeia is **not** an LLM, a model provider, a new coding agent or a
replacement for Claude Code or Codex. It never calls model APIs itself and
never runs an agent loop of its own: the harnesses do the reasoning, coding and
tool use; Khymeia handles execution, coordination, state, verification and
observability.

---

- [Status](#status)
- [Quick start](#quick-start)
- [Using Khymeia](#using-khymeia) — sessions · workflows · cloud providers
- [Harness adapters](#harness-adapters)
- [Architecture](#architecture)
- [Security and trust model](#security-and-trust-model)
- [Running as a daemon](#running-as-a-daemon)
- [Configuration](#configuration)
- [Development](#development)
- [Roadmap](#roadmap)
- [Why Elixir](#why-elixir)

## Status

Early and moving fast, but built to be trusted with real work:

| Area | State |
|---|---|
| Sessions with Claude Code and Codex | working, exercised end to end against the installed CLIs |
| Workflows (implement → audit → fix loop, advisor, human checkpoints) | working; verified with Claude Code as implementer and auditor on a test repository |
| Cloud providers (Bedrock, Foundry, Vertex, Azure OpenAI) | implemented from the CLIs' official docs; configuration accepted by the real CLIs, **not yet run against live accounts** |
| Projects and shell (sidebar, per-project overview, repository tab) | working |
| Embedded terminals (the harness's own TUI on a real pty) | working; verified end to end with the Claude Code TUI, including a model exchange |
| Terminal output saved to disk | working; survives restarting the daemon |
| Resuming a conversation from an embedded terminal | working; verified with Claude Code (exchange → `/exit` → reopen → history intact) |
| Test suite | 141 tests, no agent CLI required ([CI](.github/workflows/ci.yml)) |
| Packaging | OTP release works; Homebrew formula pending |

Every integration is checked against the installed CLI's `--help` or its
official documentation; what could not be verified is said so in this README
rather than simulated.

## Quick start

Requirements: Elixir ≥ 1.17 on OTP ≥ 26 (developed on Elixir 1.20.4 /
OTP 29.1, see [`.tool-versions`](.tool-versions)), macOS or Linux, and a C
compiler (SQLite is compiled in by `exqlite`).

```bash
mix setup          # deps, database, assets
mix phx.server
```

Open <http://127.0.0.1:4777>. Add the folder you work in as a project; the
sidebar lists the harnesses Khymeia found on your machine.

No agent CLI? In development a **Fake harness** is always available, so the
whole runtime can be tried without one. Choose it in *New session* and pick a
scenario as its "model":

| Scenario | Behaviour |
|---|---|
| `success`, `stream` | messages / twenty streamed lines, then waits for a follow-up |
| `failure` | writes to stderr and exits with status 3 |
| `hang` | never finishes — try *Stop* |
| `ask-advisor`, `ask-human` | an implementer asking Khymeia for help (workflows) |
| `advise`, `audit-pass`, `audit-findings`, `audit-fix-once` | advisor and auditor behaviours (workflows) |
| `whoami` | reports which provider profile reached the process (never the secret) |

Port 4777 keeps clear of the usual 3000/4000/5000/8080 dev ports; change it
with `KHYMEIA_PORT`.

## Using Khymeia

### Sessions

*New session → Chat*: choose a **workspace**, a **harness** (or one of its
provider profiles), a **model**, optionally a **permission mode**, and write
a prompt.

- **Workspace** — picked in a folder-browser modal (recent workspaces, allowed
  roots, git repositories marked). It only shows folders inside the allowed
  roots, and the server re-validates every step.
- **Model** — only what the CLI itself reports: Codex's catalog from
  `codex debug models`; for Claude Code, the aliases its `--help` documents
  (`fable`, `opus`, `sonnet`). *Default* leaves the choice to the harness;
  *Other…* accepts any name the CLI takes. Nothing is guessed.
- **Permissions** — the non-interactive run cannot ask for approval, so this
  decides what the agent may do on its own: Claude Code `plan`,
  `acceptEdits`, `auto`, `dontAsk`; Codex `read-only`, `workspace-write`.
  `bypassPermissions` and `danger-full-access` are deliberately not offered.

A session page streams the activity live. When the harness can resume a
conversation (both can), a finished turn leaves the session **waiting**:
reply to continue the same conversation, *Mark done*, or *Stop* it at any
time.

### Projects

A project is a folder you work in. Its **Overview** is the state of that
folder — what is running, what ran recently — not a prompt box: work starts by
opening a terminal, with the headless lanes (session, workflow) one click
away. **Git** shows what the repository looks like right now. Sessions,
workflows and terminals all belong to a project, so history stays grouped by
place.

### Terminals

*Project → Terminal* runs the harness's **own interactive interface** inside
Khymeia, on a real pseudo-terminal, in the project's folder. This is the lane
a human drives, and the point is that Khymeia does not reimplement it: model,
effort, permission mode and every slash command keep working, because it *is*
the CLI.

Khymeia owns the process, not the interface:

- the runtime spawns `priv/bin/khymeia-pty`, a small C helper that holds the
  pseudo-terminal (the BEAM cannot allocate or resize one) and relays it with
  Erlang's `{packet, 4}` framing;
- closing the helper's stdin kills the harness, so nothing outlives Khymeia —
  verified down to `kill -9` on the whole daemon;
- **output is written to disk as it happens**, so a terminal can be reopened
  and read after Khymeia itself restarted, not just after the browser closed;
- the browser's window size drives `TIOCSWINSZ`, so the TUI lays itself out
  for what you can actually see.

**Saved output is the one place Khymeia keeps raw harness output**, and a
terminal shows whatever appeared on screen. So the directory is `0700`, each
log is `0600` and capped at 1 MB, and *Delete* removes a terminal together
with everything it printed. Set `:terminal_log_dir` to move them elsewhere.

**Continuing a conversation.** There is no separate "resume" step: opening a
terminal that is not running puts a process back on it, asking the harness to
continue where it left off, and you type. It is the same terminal — same id,
same saved output — because a terminal *is* the conversation as far as the
user is concerned.

Verified end to end against Claude Code 2.1.212: an exchange, `/exit`, reopen,
and the previous exchange is there. Khymeia names the conversation itself with
`--session-id <uuid>` and reopens it with `--resume`. Codex accepts no
caller-chosen id, so it resumes with its own `resume --last` for that
workspace; that path is not yet exercised.

When the harness cannot continue (it says so and exits at once), Khymeia
prints a line saying so and starts a fresh one in the same place, rather than
handing back a terminal that died on arrival. A stop you asked for, or a
harness killed by a signal, never triggers that.

**Stop quits, it does not kill.** A harness ended by a signal loses the
conversation it was holding — measured, not assumed. So *Stop* first sends the
harness's own quit sequence (`/exit` for Claude Code, verified) and only
signals it if it will not go. Adapters without a verified quit sequence are
signalled directly, and say so rather than having one guessed for them.

**A clean environment matters more than it looks.** Khymeia is often started
from an agent's own terminal, and Claude Code exports two dozen `CLAUDE_*`
variables to its subprocesses — session ids, a messaging socket, "child
session" markers. Inheriting them made the harness Khymeia started behave as a
continuation of that session and quietly *not persist its conversation at
all*. Every adapter now clears the inherited variables of its own family
before spawning, keeping only what it sets itself. This was the whole reason
resuming appeared not to work.

**What survives, and what does not.** The *conversation* is persisted by the
harness itself; Khymeia stores its id, workspace and provider profile. The
*scrollback* lives in the terminal's process. The *process* is a child of the
runtime and dies with it — after a restart Khymeia closes the old terminal and
offers to resume the conversation rather than pretending the process is alive.

Only harnesses whose interactive mode an adapter declares are offered. A
merely detected CLI gets no invented command line.

### Workflows

*New session → Workflow* runs a declarative workflow in which each **role**
is played by the harness/model you choose. Khymeia never decides which agent
is "better".

```text
Task ─► Implementer ──(ask advisor?)──► Advisor (ephemeral session) ─┐
             ▲   ◄──────────────── answer ────────────────────────────┘
             ▼
          Auditor (fresh, read-only session)
             │
     PASS ───┴─── FINDINGS ─► Implementer (same conversation) ─► Re-audit ─► …
      │                                   at most max_iterations, then a human decides
     Done
```

**Presets:** *Simple coding* (implement) and *Coding + Audit* (implement →
audit → fix → re-audit). The run page shows the step tree (advisor calls
nested under the step that asked), the role assignments with their real
permission guarantees, human checkpoints and a unified timeline
(`YOU` / `IMPLEMENTER` / `ADVISOR` / `AUDITOR`), all live.

**Roles.** The engine only knows role *kinds*; adding `security_reviewer` or
`planner` is one entry in `Khymeia.Workflow.Role`.

| Role | Kind | Access | Notes |
|---|---|---|---|
| `implementer` | implementer | read + write | its conversation is resumed for fixes, advisor answers and human replies |
| `advisor` | consultant | read-only | ephemeral: one question, one answer, then the session ends |
| `auditor` | reviewer | read-only | a fresh, independent session for every audit |

**Read-only is only claimed when something enforces it:** Codex's
`read-only` sandbox (an OS sandbox), Claude Code's `plan` mode (its own
permission system). For a harness without a read-only mode, the UI and the
run record say plainly that it is *not* guaranteed.

**Capability tiers** (`fast`, `reasoning`, `audit`) give each role a default
harness/model — configured in `config :khymeia, :workflow_tiers` or with
`KHYMEIA_TIER_<NAME>=harness[@profile][:model]` — and you can change any of
them per run.

**How agents talk to Khymeia.** Harnesses share no structured-output format,
so roles end their reply with a tagged block any model can write and any
harness can carry as text. `Khymeia.Workflow.Protocol` is the only parsing
layer:

```text
<khymeia:ask-advisor reason="architecture">question</khymeia:ask-advisor>
<khymeia:ask-human>question</khymeia:ask-human>
<khymeia:audit>{"status": "findings", "findings": [{"severity": "high", "title": "…", "file": "…", "line": 1}]}</khymeia:audit>
```

Advisor requests pass an explicit, deterministic policy (`max_calls`,
`allowed_reasons`); the answer — or the reason it was refused — goes back
into the implementer's conversation. An audit without a readable verdict is
**never** taken as a pass.

**Human checkpoints.** A run never loops or guesses on its own; it waits,
with a reason and the matching action:

| Waiting because | You can |
|---|---|
| `clarification_requested` | answer; the reply goes into the implementer's conversation |
| `max_iterations_reached` | run one more iteration, or accept as done |
| `step_failed` (exit ≠ 0, timeout, crash) | retry the step, or accept as done |
| `unparseable_audit` | retry the audit, or accept as done |

**Changed files** come from comparing git snapshots (status + content
hashes) before and after each step, so files that were already dirty are not
blamed on the agent; the auditor gets the cumulative list plus the diff.
Outside a git repository they are reported as unknown, never guessed.

**Definitions** have the shape a YAML/JSON file will use
(`Khymeia.Workflow.Definition.from_map/1`), with only simple, explicit
conditions (`<step>.completed|failed|passed|has_findings`) and one bounded
`repeat`:

```yaml
name: coding-with-audit
roles: {implementer: {tier: fast}, advisor: {tier: reasoning}, auditor: {tier: audit}}
steps:
  - {id: implement, role: implementer}
  - {id: audit,     role: auditor}
  - {id: fix,       role: implementer, when: audit.has_findings}
  - {id: re_audit,  role: auditor,     when: fix.completed}
repeat: {from: fix, while: re_audit.has_findings}
max_iterations: 3
advisor: {max_calls: 3, allowed_reasons: [architecture, security, unclear_requirement, repeated_failure]}
```

One *iteration* is one pass over the steps; each `repeat` starts a new one.

### Cloud providers

A **provider profile** runs an installed harness against your own cloud
instead of its default backend. The CLI still runs **locally** — agent loop,
tools, permissions, your files — and only model inference goes to the
provider, which bills it. Khymeia only starts the same CLI with the
configuration each CLI documents:

| Harness → provider | Configuration |
|---|---|
| Claude Code → Amazon Bedrock | `CLAUDE_CODE_USE_BEDROCK=1`, `AWS_REGION`, AWS profile / access keys / Bedrock API key, optional `ANTHROPIC_BEDROCK_BASE_URL` |
| Claude Code → Microsoft Foundry | `CLAUDE_CODE_USE_FOUNDRY=1`, `ANTHROPIC_FOUNDRY_RESOURCE` or `…_BASE_URL`, API key or Entra ID (`az login`) |
| Claude Code → Google Vertex AI | `CLAUDE_CODE_USE_VERTEX=1`, `ANTHROPIC_VERTEX_PROJECT_ID`, `CLOUD_ML_REGION`, Application Default Credentials |
| Codex → Azure OpenAI / Foundry | `-c model_provider=…` with the v1 endpoint (`…/openai/v1`, `wire_api = "responses"`); API key (Codex has no Entra ID support) |
| Codex → Amazon Bedrock | built-in `amazon-bedrock` provider (`aws.region`, `aws.profile`) or access keys |

Codex is configured with `-c` overrides, so your `~/.codex/config.toml` is
never modified. Create profiles under **Providers**; each then appears as a
harness choice in sessions and per workflow role — e.g. the implementer on
Bedrock and the auditor on Azure OpenAI. **Models** are the provider's
identifiers (Bedrock model/inference-profile IDs or ARNs, Foundry/Azure
deployment names); a profile can carry a default, and Foundry and Codex
profiles need one.

**Credentials are never stored by Khymeia.** A profile records only *how* to
obtain one:

| Source | Details |
|---|---|
| Ambient | the provider SDK's own chain: AWS profile/SSO, `az login`, gcloud ADC |
| Environment variable | a variable of Khymeia's own process (a `brew services` daemon does not see your shell exports) |
| macOS Keychain — API key | pasted once, written to the Keychain (service `khymeia`) through `security -i` on stdin, so it never appears in any process's arguments |
| macOS Keychain — AWS access keys | access key ID, secret and optional session token entered in a form instead of editing `~/.aws/credentials` |

Stored credentials are read when each turn starts (so rotation needs no
restart), handed only to the harness process environment, and never reach
the database, events, logs or the UI. *Forget credential* removes them at
any time. When a profile names an AWS profile, inherited
`AWS_ACCESS_KEY_ID` / `AWS_BEARER_TOKEN_BEDROCK` variables are cleared for
that process — the AWS SDK would otherwise prefer them and silently use
another account.

The Providers page runs **local readiness checks only** (variable set, key in
the Keychain, AWS profile present, gcloud credentials file) — no network call,
no cost. A session is the only real test.

What was and wasn't verified: without live Bedrock/Foundry/Vertex/Azure
accounts, the profiles were probed against unreachable endpoints and AWS's
published example keys. Each CLI accepted the generated configuration and
routed to the configured provider, and both load access keys from the
environment (Codex's request was rejected by AWS with 401, as expected for
fake keys). Two findings from those probes: Codex's Bedrock provider uses
Bedrock's OpenAI-compatible endpoint, so its model must be one served there
(e.g. `openai.gpt-oss-120b-1:0`) — Claude models on Bedrock go through
Claude Code; and `env` entries in `~/.claude/settings.json` (e.g. from
`/setup-bedrock`) also apply, so keep provider settings in one place.

## Harness adapters

| Harness | Status | Driven with |
|---|---|---|
| Claude Code | integrated | `claude -p --output-format stream-json --verbose [--model] [--permission-mode] [--resume ID] -- PROMPT` |
| Codex | integrated | `codex exec --json [-m] [-c …] -- PROMPT`, `codex exec resume --json … -- THREAD PROMPT` |
| Fake | dev/test | `priv/bin/khymeia-fake-harness` |
| Kiro CLI, Copilot CLI, OpenCode, Gemini CLI | detected only | no adapter yet — the UI says so |

An adapter implements `Khymeia.Harness`. Adapters are pure modules — they
build argv, parse output lines and declare capabilities; the session process
owns the OS process:

```elixir
@callback id() :: atom()
@callback name() :: String.t()
@callback detect() :: {:ok, %{executable: path, version: String.t() | nil}} | :not_found
@callback capabilities() :: Khymeia.Harness.Capabilities.t()
@callback build_command(turn) :: {:ok, %{executable: path, args: [String.t()], env: [...]}} | {:error, term}
@callback parse_output(:stdout | :stderr, line :: String.t()) :: [event]
@callback list_models(executable) :: {:ok, [model]} | :error   # optional
@callback provider_kinds() :: [atom()]                          # optional
```

`Capabilities` declares streaming, structured output, resume, stop, model
selection (and whether the model list is closed), permission modes, the
read-only mode and who enforces it. The UI only shows controls an adapter
declares.

**Known limitations, documented rather than faked:**

- Non-interactive runs cannot ask for approval mid-turn. In `acceptEdits`,
  Claude Code cannot run shell commands (verified: an implementer could not
  run `python3`); use `auto` or allowlist commands in your Claude Code
  settings. Khymeia never bypasses permissions.
- Codex refuses to run outside a Git repository; Khymeia does not pass
  `--skip-git-repo-check`.
- Follow-up messages go between turns, not during a running turn.
- *Stop* sends SIGTERM to the harness (SIGKILL after 5 s); well-behaved CLIs
  clean up their own subprocesses.
- Activity logs live in memory (last 2 000 events, kept 30 minutes after a
  session ends); session and workflow history is persisted.
- Concurrent sessions on the same workspace are not isolated from each other
  yet — see the [roadmap](#roadmap).

**Adding an adapter:** implement `Khymeia.Harness` in
`lib/khymeia/harness/<name>.ex`, add it to `config :khymeia,
:harness_adapters`, drop it from `Khymeia.Harness.planned/0`, and test
`build_command/1` and `parse_output/2` as pure functions — no real CLI needed
(see `test/khymeia/harness/adapters_test.exs`). Take every flag from the
installed CLI's `--help` or its official docs.

## Architecture

```text
             Phoenix LiveView UI  (never spawns processes)
                        │
           ┌────────────┴────────────┐
           ▼                         ▼
   Khymeia.Runtime            Khymeia.Workflow           public APIs
   (sessions)                 (multi-agent runs)
           │                         │ owns sessions of its roles
           ▼                         ▼
   SessionSupervisor          Workflow.Supervisor        DynamicSupervisors
     └─ SessionServer ◄──────── Workflow.Server
           │  owns one Erlang Port
           ▼
     priv/bin/khymeia-exec    POSIX wrapper: stdin from /dev/null, stdout/stderr
           │                  tagged, harness killed if the port closes
           ▼
     claude -p / codex exec   the CLI you installed (optionally → your cloud)

   events ──► EventBus (Phoenix.PubSub) ──► LiveViews     no polling
   state  ──► SQLite (Ecto)                                history, workflows, profiles
```

### Supervision tree

```text
Khymeia.Application (one_for_one)
├── KhymeiaWeb.Telemetry
├── Khymeia.Repo                          SQLite
├── Ecto.Migrator                         releases migrate on boot
├── Task                                  mark work left active by a previous run
├── Phoenix.PubSub                        transport of Khymeia.Runtime.EventBus
├── Khymeia.Runtime.Supervisor (rest_for_one)
│   ├── Khymeia.Runtime.Registry          session id → pid + summary
│   ├── Khymeia.Runtime.SessionSupervisor DynamicSupervisor
│   │   └── SessionServer …               :temporary
│   ├── Khymeia.Workflow.Registry
│   ├── Khymeia.Workflow.Supervisor       DynamicSupervisor
│   │   └── Workflow.Server …             :temporary
│   ├── Khymeia.Terminals.Registry        terminal id → pid
│   ├── Khymeia.Terminals.Supervisor      DynamicSupervisor
│   │   └── Terminals.Server …            :temporary, owns one pty helper
│   ├── Khymeia.Runtime.CrashMonitor      records crashed sessions and workflows
│   └── Khymeia.Harness.Discovery         installed harnesses and their models
└── KhymeiaWeb.Endpoint
```

### Design decisions

- **Sessions and workflows are `:temporary`.** Restarting would repeat agent
  work, so a crash is *recorded* by `CrashMonitor` instead of retried; any
  number of crashes cannot exhaust a supervisor's restart intensity.
- **One owner per OS process.** Adapters are pure; the session process owns
  the port, so process lifecycle is handled in exactly one place.
- **A session is a conversation; a turn is an OS process.** When a turn
  ends, a resumable session waits; a follow-up starts a new turn in the same
  harness conversation.
- **Workflows own their sessions.** Session events are delivered to the
  owning workflow as messages (no subscription race), sessions are monitored
  (an agent crash is a failed *step*), and sessions stop themselves if their
  workflow dies.
- **The registry holds a summary per session**, so listing never blocks on a
  busy session.
- **Runtime state lives in processes; history in SQLite.** The workflow page
  and its timeline are projections of stored rows, so finished runs look the
  same after a restart. Work left active by a previous run is marked
  `interrupted`.

### Session lifecycle and events

```text
starting ──► running ──► completed     exit 0, not resumable
               │   └───► waiting ◄─┐   exit 0, resumable: accepts a follow-up
               │            └──────┘   (follow-up = new turn)
               ├───────► failed        non-zero exit, timeout, crash
               └───────► stopped       user, owner workflow gone, shutdown
```

Session events (`{:session_event, %Khymeia.Runtime.Event{}}`):
`session.started|input|resumed|output|waiting|completed|failed|stopped`, with
output kinds `assistant`, `reasoning`, `tool`, `stdout`, `stderr`, `system`,
`error`, `result`. Workflow events (`{:workflow_event, …}`):
`workflow.started|completed|failed|waiting|stopped|resumed`,
`workflow.iteration.*`, `workflow.step.*`, `advisor.*`, `audit.*`,
`human.requested|answered`.

## Security and trust model

Khymeia starts agents that read and write your files, so it assumes **one
trusted local user** and is built to be unreachable by anyone else:

- **Loopback only**, `127.0.0.1` by default, with no authentication: anyone
  who can reach the port can drive your agents. Don't bind it elsewhere
  without real authentication in front.
- **DNS-rebinding protection:** requests whose `Host` is not a loopback name
  are rejected, and LiveView sockets only accept loopback origins, so a web
  page you visit cannot talk to Khymeia.
- **No shell:** harnesses start with `Port` + argv; the prompt is one argument
  after `--`, so it cannot inject flags or shell syntax. The UI can only pick
  an installed adapter, never run a command.
- **Validated workspaces:** `~` expanded, `..` collapsed and symlinks
  resolved before checking the directory is inside the allowed roots — for
  starting sessions and for every step of the folder browser.
- **Validated options:** models match a conservative pattern; permission and
  sandbox modes must be ones the adapter declares; provider settings are
  plain values, safe as environment variables and TOML strings.
- **A clean environment:** a harness starts with the inherited variables of
  its own family cleared, so a session Khymeia starts is never a continuation
  of whatever session happened to launch Khymeia.
- **No stored secrets:** each CLI keeps its own auth; provider credentials
  are referenced, not stored (see [Cloud providers](#cloud-providers)); the
  daemon's own secrets (`SECRET_KEY_BASE`, `RELEASE_COOKIE`, `DATABASE_PATH`)
  are removed from every harness environment.
- **No orphans:** both spawn paths terminate the harness when their port
  closes — on Stop, a crash, or the VM dying. The pty helper signals the
  whole process *group*, so a TUI's own subprocesses go with it, and every
  wait it performs is bounded so it can never hang holding a terminal open.
- **Terminals are argv too:** an embedded terminal runs an adapter-built argv
  on a pseudo-terminal, never a shell. Khymeia offers one only for harnesses
  whose interactive mode an adapter declares; the UI cannot ask for an
  arbitrary command.

What Khymeia does *not* protect against: the agents themselves. A harness has
whatever power its configuration and the chosen permission mode give it.

## Running as a daemon

Khymeia is an OTP release meant to run under `launchd` / `systemd` (and,
later, `brew services`):

```bash
MIX_ENV=prod mix do compile + assets.deploy
MIX_ENV=prod mix release
_build/prod/rel/khymeia/bin/khymeia start     # foreground; `daemon` to background
```

A release needs no configuration: it migrates its database on boot and keeps
its data — including a generated cookie-signing secret (`0600`) — in
`~/Library/Application Support/Khymeia` (macOS) or `$XDG_DATA_HOME/khymeia`.

A daemon does not inherit your shell's `PATH`, so discovery also searches
`~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.npm-global/bin`,
`~/.bun/bin`, `~/.volta/bin` and `~/.cargo/bin`, and harnesses run with that
extended `PATH` (Node-based CLIs need to find `node`).

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `KHYMEIA_PORT` | `4777` | HTTP port |
| `KHYMEIA_BIND` | `127.0.0.1` | interface to bind — read [Security](#security-and-trust-model) first |
| `KHYMEIA_WORKSPACE_ROOTS` | your home directory | colon-separated directories sessions may run in |
| `KHYMEIA_TURN_TIMEOUT_SECONDS` | none | kill a turn that runs longer than this |
| `KHYMEIA_TIER_<NAME>` | see `config/config.exs` | default `harness[@profile][:model]` for a workflow tier |
| `KHYMEIA_EXTRA_PATH` | — | extra directories to search for harness CLIs |
| `KHYMEIA_<ID>_BIN` | — | pin a binary, e.g. `KHYMEIA_CLAUDE_BIN=/opt/bin/claude` |
| `KHYMEIA_ENABLE_FAKE_HARNESS` | `false` in releases | offer the demo harness |
| `KHYMEIA_DATA_DIR` | see above | database and secret location (releases) |
| `DATABASE_PATH` | per environment | database file (in dev, lets a second instance run alongside) |

Application settings (`config/config.exs`): `harness_adapters`,
`turn_timeout`, `session_retention_ms`, `max_sessions`, `max_workflows`,
`workflow_tiers`.

## Development

```bash
mix test         # 141 tests; no agent CLI needed (fake harness, in-memory secrets)
mix precommit    # compile --warnings-as-errors, unused deps, format, test
```

[CI](.github/workflows/ci.yml) runs the same checks on every push and pull
request, with the versions in `.tool-versions`.

- **The fake harness** (`priv/bin/khymeia-fake-harness`) is a real OS process
  driven through the same wrapper and port as Claude Code or Codex, so tests
  exercise the whole runtime — streaming, failures, timeouts, crashes,
  workflows, provider plumbing.
- **Tests never touch your Keychain** (`Khymeia.MemorySecrets`) and never run
  a real agent CLI.
- **Probing real CLIs** is done by hand and kept cost-free: tiny prompts,
  unreachable endpoints, documented example credentials.
- Commits follow Conventional Commits: `type(scope): summary`.

```text
lib/khymeia/
  runtime.ex  workflow.ex  providers.ex      public APIs
  projects.ex git.ex                          projects and repository state
  runtime/     supervisors, session server, registry, crash monitor, event bus, OS process
  harness/     behaviour helpers, discovery, adapters (claude, codex, fake)
  workflow/    server, definition, presets, roles, protocol, prompts, git, timeline, store
  providers/   profile schema, secrets behaviour, Keychain backend
  sessions/    session history (Ecto)
  projects/    project schema
  workspace.ex path validation and folder browsing
lib/khymeia_web/
  live/        projects, project, sessions, new session/workflow, session,
               workflow, providers
  components/  layouts (shell), session components, workspace picker
  nav.ex       sidebar state, mounted as a hook on every LiveView
  plugs/       loopback-only guard
priv/bin/      khymeia-exec (process wrapper), khymeia-fake-harness
```

## Roadmap

The aim is a local tool that makes working with several coding agents feel
controlled, observable and safe. Khymeia should stay focused: sessions,
isolated work, reviewable changes and explicit coordination rather than
becoming a general-purpose development platform. In order:

1. **Consolidate the runtime** — CI, packaging and real day-to-day use with
   Claude Code and Codex to collect friction before expanding the surface
   area. Finish the Homebrew distribution path and keep every integration
   verified against the real installed CLI.

2. **Worktree isolation** — every session or workflow gets its own git
   worktree and branch, so concurrent agents can work on the same repository
   without sharing a working tree or overwriting each other. Each isolated
   workspace exposes its base branch and commit, its session branch, changed
   files, additions and deletions, the commits the agent created, and explicit
   **keep** and **discard** actions. Khymeia never merges agent work
   automatically.

3. **Embedded terminal as the primary way to work** — run the harness's own
   interactive interface inside Khymeia, in the session's worktree and with
   its provider profile, instead of rebuilding its controls. Model, effort,
   permission mode, `/compact`, `/context` all keep working, because it is the
   real CLI; Khymeia owns and supervises the process, it does not replace the
   interface.

   Verified against the installed CLIs, and what makes this cheap:

   - Claude Code accepts `--session-id <uuid>`, so Khymeia picks the
     conversation id up front, for interactive and headless runs alike
     (confirmed: the interactive CLI creates `~/.claude/session-env/<uuid>`);
   - `--no-session-persistence` only works with `--print`. That says
     interactive sessions are meant to be saved, but in practice a
     conversation held in an embedded terminal could not be resumed
     afterwards — the open question this phase still has to answer;
   - Codex offers `resume <SESSION_ID>`, `fork`, and
     `queue --thread <id> --message <text>` to inject a message into a live
     session.

   A session therefore moves between the interactive lane and the headless one
   without losing the conversation — **take over** and **hand back**, never
   both at once. Structured events stay the job of the headless lane: a PTY
   carries bytes, not events, and audit loops cannot be built on terminal
   output.

   "State survives" means three separate things, and only two are free: the
   *conversation* (the CLI persists it; Khymeia stores id, worktree and
   profile), the *scrollback* (a bounded output buffer replayed on reattach)
   and the *live process* (a child of the runtime dies with it — recovery is
   relaunching with `--resume`, not keeping the process alive).

   To be settled by a short spike before any code is written: a PTY helper
   with window resizing (the BEAM has no PTY of its own); whether
   `codex app-server` removes the need for a PTY on the Codex side; and
   whether Claude Code hooks fire during interactive sessions and can keep the
   timeline alive while the user types.

4. **First-class changes and diffs** — make git state part of the session
   rather than a hidden implementation detail, so a session answers one
   question immediately: *what did this agent change?* Change counts on
   session cards, file-by-file diffs, a cumulative diff against the session's
   base commit, changes attributed to individual workflow steps, branch and
   worktree status, and opening the worktree in a terminal or editor. Workflow
   runs show both the total result and the changes introduced by individual
   implement/fix steps.

5. **Project and session workspace** — make active work the main view of
   Khymeia. The shell (projects, sidebar, per-project overview, repository
   tab) is in place; what remains depends on worktrees and diffs. A repository
   should show its running, waiting and completed sessions together with their
   harness, branch, worktree, change summary and current state, with multiple
   agents visible side by side without reasoning about their processes.

6. **More harness adapters** — Gemini CLI next, then GitHub Copilot CLI, Kiro
   CLI and OpenCode, where their non-interactive and resume behaviour can be
   verified reliably. Detection alone is not integration: every adapter must
   document its actual capabilities, permissions, resume semantics and
   limitations.

7. **Continuity and session history** — persist activity beyond the current
   in-memory event window and make interrupted work recoverable when the
   harness supports it: persisted activity timelines, conversation
   identifiers, interrupted-session recovery, usage and cost where the harness
   exposes it, and durable branch/worktree metadata.

8. **Cross-harness handoff** — allow a task to continue in another harness
   without pretending native conversation identifiers are portable between
   providers. A handoff creates a new session with explicit context derived
   from the current work — original task, current objective, worktree and
   branch, changed files and diff, completed work, relevant previous output,
   open questions, verification state — and the receiving harness starts a new
   native conversation over the same controlled workspace.

9. **Implementers that verify** — give workflow roles explicit verification
   capabilities instead of trusting completion claims: per-role allowed
   commands, repository-defined verification commands, tests, linting and
   build results captured as workflow events, results passed to auditors, and
   a clear distinction between model claims and checks Khymeia actually ran.

10. **Workflow evolution** — keep workflows deterministic while making them
    more useful: reusable workflow definitions, additional reviewer and
    planner role kinds, richer but still bounded conditions, step-level diffs
    and verification, explicit human approval points, and comparison of
    independent implementations without automatically choosing a winner.

11. **Optional context integration** — let external repository-context tooling
    prepare or synchronize harness-specific instructions before a session
    starts, without making Khymeia responsible for organisation-wide
    knowledge.

Deliberately out of scope: a model or agent loop of Khymeia's own, direct
model API calls, automatic task decomposition, autonomous model routing,
automatic merging, remote execution, multi-user collaboration and
organisation-wide context platforms.

The developer remains responsible for choosing the harness, reviewing its work
and deciding what reaches the repository's main branch.

## Why Elixir

Supervising agent sessions is the problem OTP was designed for:
long-running, isolated processes with their own state; supervision that
defines exactly what happens when one crashes, hangs or floods output;
message passing from ports to sessions to any number of listeners; and
LiveView, which turns those events into live pages with no separate frontend
or polling. Independent agent sessions *are* independent processes, and
handoffs between agents are messages between them.

## License

To be decided before the first public release.
