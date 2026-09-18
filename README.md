# Khymeia

**Khymeia is a local-first runtime to supervise and coordinate the coding-agent
harnesses you already have installed** — Claude Code, Codex, and (soon) Kiro CLI,
GitHub Copilot CLI, OpenCode, Gemini CLI.

It runs as a long-lived local daemon, launches harness sessions as supervised
OTP processes, streams their output as events, and shows everything live in a
Phoenix LiveView UI at <http://127.0.0.1:4777>.

On top of single sessions, **workflows** coordinate several harnesses in
roles — an *implementer* that writes code, an ephemeral *advisor* it can
consult, and an independent read-only *auditor* whose findings loop back to
the implementer — with Khymeia as supervisor and orchestrator
([Workflows](#workflows)).

## What Khymeia is not

Khymeia is **not**:

- an LLM, or a model provider;
- a new coding agent, or an agent loop of its own;
- a replacement for Claude Code or Codex.

It never calls model APIs and never handles credentials. Every session runs the
real CLI you installed, with the authentication that CLI already has.

## Quick start

Requirements: Elixir ≥ 1.17 / OTP ≥ 26 on macOS or Linux, and a C compiler
(SQLite is compiled in by `exqlite`).

```bash
mix deps.get
mix ecto.setup
mix phx.server     # or simply: mix setup && mix phx.server
```

Open <http://127.0.0.1:4777>. The dashboard lists which harnesses were detected.
In development a **Fake harness** is always available so you can try the whole
runtime without any agent CLI: choose it on *New session*, pick a scenario as
its "model" (`success`, `stream`, `failure`, `hang`) and watch the session
stream, wait for input, fail or get stopped.

```bash
mix test           # 106 tests, no real harness required
```

Port 4777 was chosen to stay clear of the usual 3000/4000/5000/8080 dev ports;
override it with `KHYMEIA_PORT`.

## Architecture

```text
                 Phoenix / LiveView  (UI — never spawns processes)
                          │
                          ▼
                  Khymeia.Runtime     (public API: start / stop / send / list)
                          │
          ┌───────────────┼───────────────────────┐
          ▼               ▼                       ▼
   Runtime.Registry   SessionSupervisor     Harness.Discovery
   (id → pid, summary) (DynamicSupervisor)   (what is installed)
                          │
          ┌───────────────┼────────────────┐
          ▼               ▼                ▼
    SessionServer   SessionServer    SessionServer      one GenServer per session,
     (Claude)         (Codex)          (Fake)           owns one Erlang Port
          │               │                │
          ▼               ▼                ▼
     khymeia-exec    khymeia-exec     khymeia-exec      POSIX wrapper (priv/bin)
          │               │                │
          ▼               ▼                ▼
      claude -p      codex exec     fake harness       the harness you installed

   SessionServer ──publish──► EventBus (Phoenix.PubSub) ──► LiveViews (no polling)
                 ──persist──► Sessions (Ecto + SQLite)
```

### Supervision tree

```text
Khymeia.Application (one_for_one)
├── KhymeiaWeb.Telemetry
├── Khymeia.Repo                         SQLite
├── Ecto.Migrator                        (releases migrate on boot)
├── Task: mark sessions left active by a previous run as failed
├── Phoenix.PubSub (Khymeia.PubSub)      transport of Khymeia.Runtime.EventBus
├── Khymeia.Runtime.Supervisor (rest_for_one)
│   ├── Khymeia.Runtime.Registry
│   ├── Khymeia.Runtime.SessionSupervisor   DynamicSupervisor
│   │   ├── SessionServer  #1  (:temporary)
│   │   └── SessionServer  #2  (:temporary)
│   ├── Khymeia.Workflow.Registry
│   ├── Khymeia.Workflow.Supervisor         DynamicSupervisor
│   │   ├── Workflow.Server  #1  (:temporary)
│   │   └── Workflow.Server  #2  (:temporary)
│   ├── Khymeia.Runtime.CrashMonitor        records crashed sessions/workflows
│   └── Khymeia.Harness.Discovery           cached detection results
└── KhymeiaWeb.Endpoint
```

Design decisions worth knowing:

- **Sessions are `:temporary`.** Restarting a session would re-run its prompt,
  and a coding agent must never silently repeat work. A crash is *recorded*
  (by `CrashMonitor`, which monitors every session and workflow) instead of retried. Since
  temporary children don't count towards restart intensity, any number of
  crashing sessions cannot take the supervisor down.
- **Adapters are not processes.** `Khymeia.Harness` adapters only build argv,
  parse output lines and declare capabilities. The session process owns the
  port, so there is exactly one place where process lifecycle is handled.
- **A session is a conversation, a turn is an OS process.** When a harness can
  resume (Claude Code `--resume`, Codex `exec resume`), a finished turn moves
  the session to `waiting`; sending a message starts a new turn in the same
  harness conversation.
- **The Registry holds a summary per session**, so listing sessions reads ETS
  and never blocks on a busy session process.
- **The runtime state lives in processes; history lives in SQLite.** Only
  operational context is persisted (harness, workspace, prompt, status,
  timestamps, exit code, harness conversation id, basic metadata). Output is
  kept in memory by the session process (last 2 000 events) and for 30 minutes
  after it finishes (`session_retention_ms`).

### Session lifecycle

```text
starting ──► running ──► completed        exit 0, harness cannot resume
               │   └───► waiting ◄──┐     exit 0, harness can resume
               │            │       │
               │            └► running (follow-up message: new turn)
               ├───────► failed           non-zero exit, turn timeout, crash
               └───────► stopped          user request / runtime shutdown
```

### Events

Published on `Khymeia.Runtime.EventBus` (Phoenix PubSub) as
`{:session_event, %Khymeia.Runtime.Event{}}`:

| event               | when                                                   |
|---------------------|--------------------------------------------------------|
| `session.started`   | first turn's process is running                        |
| `session.input`     | a user message (the prompt or a follow-up)             |
| `session.resumed`   | a follow-up turn started                               |
| `session.output`    | output, with `kind`: assistant, reasoning, tool, stdout, stderr, system, error, result |
| `session.waiting`   | turn finished; the session accepts a message           |
| `session.completed` | finished successfully                                  |
| `session.failed`    | non-zero exit, timeout or crash                        |
| `session.stopped`   | stopped by the user or by runtime shutdown             |

The session view renders `input` and assistant `output` as conversation turns
(`YOU` / `CLAUDE CODE`) and the rest as a compact log. Events carry a role
(`:user`, `:harness`, `:runtime`), which is what a future multi-harness
conversation — `@codex review what claude just did` — will group by. Sessions
stay independent internally; a conversation will be a view over their events.

## Workflows

A workflow is a run of a declarative definition in which **roles** are played
by the harnesses you choose. Khymeia never decides which agent is "better":
you map `role → harness/model`; Khymeia handles execution, coordination,
state, handoffs, supervision, recovery and observability; the harnesses do the
reasoning, coding and tool use. No harness ever talks to another directly —
every handoff goes through the runtime.

```text
Task ─► Implementer ──(ask advisor?)──► Advisor (ephemeral session) ─┐
             ▲   ◄──────────────── answer ────────────────────────────┘
             │
             ▼
          Auditor (fresh, read-only session)
             │
     PASS ───┴─── FINDINGS ─► Implementer (same conversation) ─► Re-audit ─► …
      │                                    at most max_iterations, then a human decides
     Done
```

Start one from **New session → Workflow** (or `Khymeia.Workflow.start/2`):
workspace, preset, task, optional architectural constraints, a harness/model
per role and `max_iterations`. `/workflows/:id` shows the step tree (advisor
calls nested under the step that asked), the role assignments and their real
permission guarantees, human checkpoints, and a unified timeline — all pushed
over PubSub.

### Processes

Each run is a `Khymeia.Workflow.Server` (`:temporary`) under its own
`DynamicSupervisor`. Every agent it uses is an ordinary supervised session
whose **owner** is the workflow: session events are delivered to the owner as
messages (no subscription race), sessions are monitored (an agent crash is a
failed *step*, not a workflow crash), and if the workflow dies its sessions
stop themselves. Advisors are ephemeral sessions that terminate as soon as
they answer. A crashed workflow is recorded as failed by `CrashMonitor`;
other workflows and the runtime are unaffected (all covered by tests).

### Roles, kinds and tiers

| role | kind | permissions | notes |
|---|---|---|---|
| `implementer` | implementer | read + write | its conversation is resumed for fixes, advisor answers and human replies |
| `advisor` | consultant | read-only | ephemeral; one question, one answer |
| `auditor` | reviewer | read-only | a fresh, independent session per audit |

The engine only knows role *kinds*, so `security_reviewer`, `test_reviewer`
(reviewers), `planner`, `architect` (consultants) or `debugger` (implementer)
are one entry in `Khymeia.Workflow.Role` away. Default assignments come from
**capability tiers** (`fast`, `reasoning`, `audit`) in
`config :khymeia, :workflow_tiers` or `KHYMEIA_TIER_FAST=claude:sonnet`,
`KHYMEIA_TIER_AUDIT=codex`; a tier without a model leaves the choice to the
harness.

**Read-only is only claimed when something enforces it:**

| harness | read-only mode | enforced by |
|---|---|---|
| Codex | `sandbox_mode="read-only"` | Codex's OS sandbox |
| Claude Code | `--permission-mode plan` | Claude Code's permission system (not an OS sandbox) |
| Fake / adapters without a read-only mode | — | **nothing**: the UI and the run record say so |

### Definitions and presets

Presets: **Simple coding** (`implement`) and **Coding + Audit**
(`implement → audit → fix → re_audit`). They are written in the shape any
future YAML/JSON file will use (`Khymeia.Workflow.Definition.from_map/1`):

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

Conditions are only `<step>.completed|failed|passed|has_findings`, and
`repeat` is the only loop. One *iteration* is one pass over the steps; each
`repeat` starts a new one. When the loop would exceed `max_iterations` the run
stops in `waiting` (`max_iterations_reached`) — it never continues on its own.

### How agents talk to Khymeia

Harnesses have no common structured-output format, so roles end their reply
with a tagged block any model can write and any harness can carry as text
(`Khymeia.Workflow.Protocol`, the only parsing layer):

```text
<khymeia:ask-advisor reason="architecture">question</khymeia:ask-advisor>
<khymeia:ask-human>question</khymeia:ask-human>
<khymeia:audit>{"status": "findings", "findings": [{"severity": "high", "title": "…", "file": "…", "line": 1}]}</khymeia:audit>
```

An implementer that asks for the advisor ends its turn; Khymeia checks the
escalation policy (the reason is stated explicitly by the agent and matched
against `allowed_reasons`; `max_calls` is counted), runs the advisor, and
resumes the implementer's conversation with the answer — or with the reason
the request was refused or failed. The same consultation is available as
`Khymeia.Workflow.ask(id, :advisor, %{type: :architecture_question, question: …})`.
An auditor reply without a readable verdict is **never** assumed to pass: the
run waits for a human (`unparseable_audit`).

### Human checkpoints

`waiting` always has a reason, and the run page offers the matching action:

| reason | action |
|---|---|
| `clarification_requested` | answer; the reply is sent into the implementer's conversation |
| `max_iterations_reached` | run one more iteration, or accept as done |
| `step_failed` (exit ≠ 0, timeout, crash) | retry the step, or accept as done |
| `unparseable_audit` | retry the audit, or accept as done |

### Changed files, diffs and results

Each implementer step yields a `StepResult` (`summary`, `changed_files`).
Changed files come from comparing git snapshots (status + content hashes)
before and after the step, so pre-existing dirty files are not blamed on the
agent; the auditor gets the cumulative list plus `git diff` of tracked files.
Outside a git repository `changed_files` is `nil` ("unknown"), never guessed.
Khymeia does not run tests itself; implementers and auditors report what they
ran, within their permissions.

### Events and persistence

`workflow.started|completed|failed|waiting|stopped|resumed`,
`workflow.iteration.started|completed`, `workflow.step.started|completed|failed`,
`advisor.started|completed|failed`, `audit.started|completed|findings`,
`human.requested|answered` — on `"workflow:<id>"` and `"workflows"`.

Runs (`workflows` table) store the definition, role assignments, status,
waiting reason, iteration, advisor call count and timestamps; steps
(`workflow_steps`) store role, harness/model/permission, session id, input,
summary, changed files, audit verdict and errors. The detail page and its
timeline are projections of these rows, so finished runs look the same after
a restart. Runs left active by a previous process are marked failed
(`interrupted`) at boot; external processes are not re-attached.

### Workflow limitations

- **Claude Code in `acceptEdits` cannot run shell commands** in
  non-interactive mode (verified: an implementer could not run `python3`).
  To let an implementer run tests, choose `auto` or allowlist commands in
  your Claude Code settings; Khymeia does not bypass permissions.
- **Advisor answers and human replies need a resumable implementer**
  (Claude Code, Codex). Otherwise those instructions are not offered to it.
- The advisor is consulted between the implementer's turns, not mid-turn.
- Harness-native structured output (Claude's `--json-schema`, Codex's
  `--output-schema`) could replace the tagged blocks per adapter later.

## Harness adapters

Each adapter implements `Khymeia.Harness`:

```elixir
@callback id() :: atom()
@callback name() :: String.t()
@callback detect() :: {:ok, %{executable: path, version: String.t() | nil}} | :not_found
@callback capabilities() :: Khymeia.Harness.Capabilities.t()
@callback build_command(turn) :: {:ok, %{executable: path, args: [String.t()], env: [...]}} | {:error, term}
@callback parse_output(:stdout | :stderr, line :: String.t()) :: [event]
@callback list_models(executable) :: {:ok, [model]} | :error   # optional
```

`Capabilities` declares `streaming`, `structured_output`, `programmatic_mode`,
`resume`, `stop`, `model_selection`, `models` (a fixed closed list, or
`:unknown` when free-form names are accepted) and `permission_modes`. Adapters
whose CLI can report its models also implement the optional
`list_models/1`; discovery caches the result. The UI shows
controls only for what an adapter declares.

| harness | status | how it is driven |
|---|---|---|
| Claude Code | integrated | `claude -p --output-format stream-json --verbose [--model] [--permission-mode] [--resume ID] -- PROMPT` |
| Codex | integrated | `codex exec --json [-m] [-c sandbox_mode=…] -- PROMPT`, `codex exec resume --json … -- THREAD PROMPT` |
| Fake | integrated (dev/test) | `priv/bin/khymeia-fake-harness` |
| Kiro CLI, Copilot CLI, OpenCode, Gemini CLI | detected only | no adapter yet — the dashboard says so |

Flags were taken from the installed CLIs' own `--help` (Claude Code 2.1,
Codex 0.154), and both integrations were exercised end to end.

### Known limitations (documented rather than faked)

- **Models come from the CLIs themselves, never from a hard-coded list.**
  Codex: `codex debug models` (its own catalog; only models Codex shows in
  its picker, in its order). Claude Code has no command to list models, so
  Khymeia offers the aliases the installed CLI documents in `claude --help`
  (`fable`, `opus`, `sonnet` today). Lists are read at discovery time and on
  *Rescan*. "Other…" still accepts any model name the CLI takes, and
  "Default" leaves the choice to the harness configuration. If a CLI changes
  its output format, the list is simply empty.
- **No interactive approvals.** Both CLIs run non-interactively, so they cannot
  ask for permission mid-turn. What they may do is decided by the permission
  mode (Claude Code: `plan`, `acceptEdits`, `auto`, `dontAsk`) or sandbox mode
  (Codex: `read-only`, `workspace-write`), or by your CLI configuration.
  `bypassPermissions` and `danger-full-access` are deliberately not offered.
- **Codex requires a Git repository.** Khymeia does not pass
  `--skip-git-repo-check`; that is Codex's safety decision to make.
- **Messages go between turns, not during them.** Follow-ups resume the
  conversation after a turn finishes; injecting input into a running turn
  (e.g. Claude Code's `--input-format stream-json`) is future work.
- **Stopping sends SIGTERM to the harness** (SIGKILL after 5 s). Well-behaved
  CLIs clean up their own tool subprocesses; Khymeia does not manage process
  groups.
- **Activity is not persisted** across restarts of the runtime, only session
  metadata.

### Adding an adapter

1. Create `lib/khymeia/harness/<name>.ex` implementing `Khymeia.Harness`.
2. Add it to `config :khymeia, :harness_adapters`.
3. Remove it from `Khymeia.Harness.planned/0` if it was listed there.
4. Test `build_command/1` and `parse_output/2` as pure functions (see
   `test/khymeia/harness/adapters_test.exs`); no real CLI is needed.

## Running as a daemon

Khymeia is an OTP release, meant to run under `launchd` / `systemd` — and,
eventually, `brew services start khymeia`.

```bash
MIX_ENV=prod mix do compile + assets.deploy
MIX_ENV=prod mix release
_build/prod/rel/khymeia/bin/khymeia start     # foreground; `daemon` to background
```

A release needs no configuration: it migrates its database on boot, and stores
data in `~/Library/Application Support/Khymeia` (macOS) or
`$XDG_DATA_HOME/khymeia`, including a generated cookie-signing secret (`0600`).

| variable | default | purpose |
|---|---|---|
| `KHYMEIA_PORT` | `4777` | HTTP port |
| `KHYMEIA_BIND` | `127.0.0.1` | interface to bind; see Security before changing |
| `KHYMEIA_WORKSPACE_ROOTS` | your home dir | colon-separated directories sessions may run in |
| `KHYMEIA_TURN_TIMEOUT_SECONDS` | none | kill a turn that runs longer than this |
| `KHYMEIA_DATA_DIR` | see above | database and secret location |
| `KHYMEIA_EXTRA_PATH` | — | extra directories to search for harness CLIs |
| `KHYMEIA_<ID>_BIN` | — | pin a binary, e.g. `KHYMEIA_CLAUDE_BIN=/opt/bin/claude` |
| `KHYMEIA_ENABLE_FAKE_HARNESS` | `false` | offer the demo harness in a release |
| `KHYMEIA_TIER_<NAME>` | see config | default `harness[:model]` for a workflow tier |
| `DATABASE_PATH` | per env | database file (also in dev, to run a second instance) |

A daemon does not inherit your shell's `PATH`, so discovery also searches
`~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.npm-global/bin`,
`~/.bun/bin`, `~/.volta/bin` and `~/.cargo/bin`, and harnesses are launched
with that extended `PATH` (Node-based CLIs need to find `node`).

## Security and local trust model

Khymeia can start coding agents that read and write your files, so it assumes
**one trusted local user** and is built to be unreachable by anyone else:

- **Loopback only.** It binds to `127.0.0.1` by default. There is no
  authentication: anyone who can reach the port can drive your agents. Do not
  bind it to another interface unless you put real authentication in front.
- **DNS-rebinding protection.** HTTP requests whose `Host` is not `localhost`,
  `127.0.0.1` or `[::1]` are rejected, and LiveView sockets only accept those
  origins, so a web page you visit cannot talk to Khymeia.
- **No shell.** Harnesses are started with `Port` + argv. The prompt is a single
  argument after `--`, never interpolated into a command string, so it cannot
  inject flags or shell syntax. The UI cannot run arbitrary commands: it can
  only pick an installed adapter.
- **Validated workspaces.** Paths are expanded, `..` collapsed and symlinks
  resolved before checking they are directories inside the allowed roots.
  Workspaces are chosen in a folder-browser modal served by the runtime (a
  browser's native folder dialog never reveals absolute paths); it lists
  folder names only, and only inside those same roots — every navigation
  and selection is re-validated on the server.
- **Validated options.** Models must match a conservative pattern; permission
  and sandbox modes must be one the adapter declares.
- **No secrets.** Khymeia stores no tokens or API keys; each CLI keeps its own
  auth. The daemon's own secrets (`SECRET_KEY_BASE`, `RELEASE_COOKIE`,
  `DATABASE_PATH`) are removed from the harness environment.
- **No orphans.** `priv/bin/khymeia-exec` terminates the harness when its port
  closes — on Stop, on a session crash, or if the VM dies.

What Khymeia does *not* protect against: the agents themselves. A harness has
whatever power its own configuration and the chosen permission mode give it.

## Why Elixir

Supervising agent sessions is the problem OTP was designed for:

- **Long-running processes** — a daemon that runs for weeks, with each session
  as a cheap, isolated BEAM process holding its own state.
- **Supervision and fault isolation** — a harness that crashes, hangs or floods
  output affects its own process only; supervisors define exactly what happens
  next.
- **Message passing** — port output arrives as messages to the session that
  owns it; events fan out through PubSub to any number of listeners.
- **Real-time UI for free** — LiveView turns those events into live pages with
  no separate frontend, API layer or polling.
- **A natural model** — independent agent sessions *are* independent
  processes; future handoffs between agents are messages between them.

## Project layout

```text
lib/khymeia/
  runtime.ex                  public API (sessions)
  workflow.ex                 public API (workflows)
  workflow/
    server.ex  supervisor.ex  definition.ex  presets.ex  role.ex
    protocol.ex  prompts.ex  git.ex  timeline.ex
    run.ex  step.ex  store.ex  results.ex  event.ex
  session.ex                  runtime snapshot struct + status lifecycle
  workspace.ex                path validation
  harness.ex                  adapter behaviour + known harnesses
  harness/
    capabilities.ex  discovery.ex  executable.ex
    claude.ex  codex.ex  fake.ex  summary.ex
  runtime/
    supervisor.ex  session_supervisor.ex  session_server.ex
    crash_monitor.ex  registry.ex  event.ex  event_bus.ex  os_process.ex
  sessions.ex                 persistence context
  sessions/session_record.ex  Ecto schema
lib/khymeia_web/
  live/  dashboard_live.ex  session_new_live.ex  session_live.ex
         workflow_new_live.ex  workflow_live.ex
  components/session_components.ex
  plugs/local_only.ex
priv/bin/
  khymeia-exec                process wrapper (stdin, stderr tagging, cleanup)
  khymeia-fake-harness        demo/test harness
```

## Not in scope (yet)

Deliberately left out so far: visual workflow editors, LLM-generated
workflows, automatic model routing or benchmarking, direct model API calls, an agent loop, MCP/A2A
servers, multi-user, authentication, cloud deployment, clustering, RAG or
vector memory, and issue-tracker integrations.

## License

To be decided before the first public release.
