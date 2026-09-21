<p align="center">
  <img src="priv/static/images/alkim-mark-512.png" alt="Alkim logo" width="112" />
</p>

<h1 align="center">Alkim</h1>

<p align="center"><strong>A local workspace for your coding agents.</strong></p>

<p align="center">
  <a href="https://github.com/alexvinola/alkim/actions/workflows/ci.yml"><img src="https://github.com/alexvinola/alkim/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
</p>

Run Claude Code and Codex from one place, give parallel tasks their own Git
worktrees, and follow the work from the first prompt to an independent audit.
Alkim brings projects, interactive terminals, background sessions and
multi-agent workflows into a local web interface.

Your installed CLIs do the coding. Alkim manages their processes, workspaces,
coordination and history. You choose the harness and model, answer when an
agent needs input, review the changes and decide what to merge.

## Why Alkim

Working with several coding agents quickly becomes a coordination problem:
which terminal belongs to which task, which branch an agent is editing,
whether it is still running, and who has checked the result. Alkim keeps
that context attached to the work.

| When you need to… | Alkim provides… |
|---|---|
| Keep track of work across repositories | A project dashboard with active work, recent activity and installed harnesses |
| Use the CLI you already know | Embedded terminals running the harness's real interactive interface, including its slash commands |
| Run separate tasks in the same repository | Git worktrees with their own directories and branches, plus change summaries |
| Delegate a task and follow its progress | Background sessions with streamed activity, follow-up messages and stop controls |
| Get a second agent to review an implementation | Explicit implement → audit → fix workflows, optional advisor consultations and human checkpoints |
| Find work again | A searchable Sessions view with terminal, session and workflow filters |
| Use your existing cloud setup | Provider profiles passed to the local CLI, with credentials resolved when it starts work |

**Local-first describes the workspace and runtime.** Alkim runs on your
machine and stores its records locally. The selected harness still uses its
configured model backend, which may send prompts and code to a cloud
provider. Alkim does not call model APIs or run a separate agent loop.

[Quick start](#quick-start) · [Using Alkim](#using-alkim) ·
[Harness adapters](#harness-adapters) · [Architecture](#architecture) ·
[Security](#security-and-trust-model) · [Configuration](#configuration) ·
[Development](#development) · [Roadmap](#roadmap)

## Status

Alkim is in active development. The current implementation includes:

| Area | Available now | Limits |
|---|---|---|
| Claude Code and Codex | Background sessions, streamed events and embedded terminals | Resume and permission behaviour depend on the adapter; see below |
| Projects and navigation | Overview, Git state, active work, search and type filters | One trusted local user |
| Worktree isolation | New or existing branches for terminals, sessions and workflows | Work started directly in a shared folder remains shared; no automatic merging |
| Workflows | Implementer, advisor, independent auditor, bounded fix loops and human checkpoints | An audit verdict is an agent's assessment, not proof that tests passed |
| Persistence | Session/run records, workflow timelines and bounded terminal output on disk | Live processes stop with the daemon; detailed session activity is held in memory |
| Cloud profiles | Claude Code: Bedrock, Foundry, Vertex; Codex: Azure OpenAI/Foundry, Bedrock | Configuration plumbing is implemented; end-to-end use with live cloud accounts remains unverified |
| Distribution | Source checkout and OTP release | Homebrew packaging is pending |

Kiro CLI, GitHub Copilot CLI, OpenCode and Gemini CLI are **detected only**;
they cannot be launched through Alkim until an adapter is implemented.

## Quick start

Requirements: macOS or Linux, Git, a C compiler, and the Elixir/OTP versions
in [`.tool-versions`](.tool-versions). The compiler builds SQLite support and
Alkim's PTY helper. Install and authenticate Claude Code or Codex separately
to use real agents; the development demo also works without them.

```bash
git clone https://github.com/alexvinola/alkim.git
cd alkim
mix setup          # deps, database, assets
mix phx.server
```

Open <http://127.0.0.1:4777>, then:

1. **Add a project** by choosing a folder on your machine.
2. **Open a terminal** from the project overview and select an available
   harness. Use its normal interface to work on the project.
3. **Create a worktree** before starting an independent task in the same
   repository, then use *Open terminal here*.
4. For a delegated task, choose **New session**; for an implementation with
   a separate review, choose **New workflow → Coding + Audit**.
5. Follow active work from **Projects** or **Sessions**, then inspect the
   repository or worktree changes before integrating them.

No agent CLI? In development a **Fake harness** is always available, so the
whole runtime can be tried without one. Choose it in *New session* and pick a
scenario as its "model":

| Scenario | Behaviour |
|---|---|
| `success`, `stream` | messages / twenty streamed lines, then waits for a follow-up |
| `failure` | writes to stderr and exits with status 3 |
| `hang` | never finishes — try *Stop* |
| `ask-advisor`, `ask-human` | an implementer asking Alkim for help (workflows) |
| `advise`, `audit-pass`, `audit-findings`, `audit-fix-once` | advisor and auditor behaviours (workflows) |
| `whoami` | reports which provider profile reached the process (never the secret) |

Port 4777 keeps clear of the usual 3000/4000/5000/8080 dev ports; change it
with `ALKIM_PORT`.

## Using Alkim

Choose the mode that matches how you want to work:

| Mode | You provide | What runs |
|---|---|---|
| Terminal | Interactive input in the CLI | The harness's own TUI on a real pseudo-terminal |
| Session | A task, model and permission mode | A non-interactive CLI turn with structured activity and follow-ups |
| Workflow | A task, role assignments and iteration limits | A deterministic sequence of sessions for implementation, advice and review |

All three are tied to a project and can use a worktree. The **Sessions** page
brings active and recent work together; search by task, harness or workspace,
or filter by type.

### Projects

A project is a folder you work in. **Overview** shows running and recent work
and lets you launch a terminal, session or workflow. **Git** shows repository
state and recent commits; worktree cards show each isolated task's branch
and change summary.

The interface supports light and dark themes. Collapse the sidebar to an
icon rail, hover over it to reveal the menu temporarily, or use the button
beside the logo to keep it open. On desktop and tablet the workspace and
terminal resize with the menu; small mobile screens use an overlay.

### Sessions

*New session → Chat*: choose a **workspace**, a **harness** (or one of its
provider profiles), a **model**, optionally a **permission mode**, and write
a prompt.

- **Workspace** — picked in a folder-browser modal (recent workspaces, allowed
  roots, git repositories marked). It only shows folders inside the allowed
  roots, and the server re-validates every step.
- **Model** — only what the CLI itself reports: Codex's catalog from
  `codex debug models`; for Claude Code, the aliases its `--help` documents
  (parsed from the installed CLI). *Default* leaves the choice to the harness;
  *Other…* accepts any name the CLI takes. Nothing is guessed.
- **Permissions** — the non-interactive run cannot ask for approval, so this
  decides what the agent may do on its own: Claude Code `plan`,
  `acceptEdits`, `auto`, `dontAsk`; Codex `read-only`, `workspace-write`.
  `bypassPermissions` and `danger-full-access` are deliberately not offered.

A session page streams the activity live. When the harness can resume a
conversation (both can), a finished turn leaves the session **waiting**:
reply to continue the same conversation, *Mark done*, or *Stop* it at any
time.

### Worktrees

Two agents in one repository is the sharpest edge Alkim has: they share a
working tree, overwrite each other's edits, and an auditor cannot tell whose
change is whose. *Project → Overview → New worktree* gives a piece of work its
own directory and its own branch, off the current `HEAD`.

- The directory is created **beside** the repository
  (`<repo>-alkim-<slug>`), because inside it every `git status` in the
  project would report it as untracked files. It has to be inside the allowed
  workspace roots like any other workspace, and Alkim says so if it is not.
- Each worktree shows what the agent actually did there, read from git: files
  touched, insertions and deletions against the base commit, commits made,
  untracked files.
- *Open terminal here* runs a harness inside the worktree. The terminal still
  belongs to the project, even though the directory sits next to it.
- A worktree can start a **new branch** or check out an **existing** one. A
  branch already checked out somewhere is offered as unavailable rather than
  as a choice that fails on submit, because git refuses to have one branch in
  two worktrees.
- The **New session** and **New workflow** forms offer the same choice — the
  project folder, a fresh worktree, or one that already exists. A workflow
  run defaults to a fresh one, because several agents in one folder is
  exactly the case isolation is for: the auditor then sees what the
  implementer changed and nothing else.
- A fresh worktree's branch is named after the work (`alkim/add-a-greeting-…`),
  so it is recognisable in `git branch`.
- Where isolation is not possible — the project is not a repository, or the
  directory beside it falls outside the allowed roots — the form says so and
  does not offer it, rather than failing on submit.

**Alkim never merges automatically.** *Keep branch* removes the worktree
directory and retains the branch; *Discard* removes both. Commit any changes
you want to retain before releasing a worktree: keeping the branch does not
save uncommitted or untracked files from the removed directory. Work launched
in the project folder edits that checkout directly.

### Terminals

Open a terminal from a project's overview or a worktree card. The terminal
runs the harness's **own interactive interface** on a real pseudo-terminal.
Its model controls, permission prompts and slash commands stay with the CLI.
Alkim manages the process, the working directory and saved output.

- Closing the browser leaves the process running while Alkim is running.
- The terminal adjusts its rows and columns when the pane resizes, including
  when the sidebar opens or closes.
- Output is saved as it arrives. Each log is bounded to 1 MB, with `0700`
  directory permissions and `0600` file permissions. **Delete** removes both
  the terminal record and its saved output.
- Opening a stopped terminal starts the harness again and asks it to resume
  the conversation, keeping the same Alkim terminal record.
- **Stop** uses the adapter's quit sequence where one is defined, then falls
  back to signals. Claude Code's adapter sends `/exit` first.

There are three kinds of state, with different lifetimes:

| State | Owner | After Alkim restarts |
|---|---|---|
| Conversation | The harness | Resumable through the CLI when supported and persisted |
| Terminal output | Alkim's bounded disk log | Saved output remains available |
| Live process | Alkim's supervised PTY helper | Stops with Alkim; reopening starts a new process |

**Resume differs by harness.** Claude Code uses a conversation UUID chosen
by Alkim and reopens it with `--resume`; this path has been exercised end to
end. Codex uses a known conversation ID when available, otherwise
`resume --last` in the workspace. The latter may select another conversation
in that folder and remains unverified end to end.

If a resume attempt exits immediately with a failure, Alkim can report the
failure and start a fresh conversation in the same workspace. A user-requested
stop or a signal termination does not trigger this fallback.

The PTY transport is a small C helper, `priv/bin/alkim-pty`, which relays
bytes and window-size changes between the CLI and the runtime. Structured
workflow activity uses the background-session adapter instead of parsing
the terminal's screen output.

### Workflows

*New session → Workflow* runs a declarative workflow in which each **role**
is played by the harness/model you choose. Alkim never decides which agent
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
`planner` is one entry in `Alkim.Workflow.Role`.

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
harness/model — configured in `config :alkim, :workflow_tiers` or with
`ALKIM_TIER_<NAME>=harness[@profile][:model]` — and you can change any of
them per run.

**How agents talk to Alkim.** Harnesses share no structured-output format,
so roles end their reply with a tagged block any model can write and any
harness can carry as text. `Alkim.Workflow.Protocol` is the only parsing
layer:

```text
<alkim:ask-advisor reason="architecture">question</alkim:ask-advisor>
<alkim:ask-human>question</alkim:ask-human>
<alkim:audit>{"status": "findings", "findings": [{"severity": "high", "title": "…", "file": "…", "line": 1}]}</alkim:audit>
```

Advisor requests pass an explicit, deterministic policy (`max_calls`,
`allowed_reasons`); the answer — or the reason it was refused — goes back
into the implementer's conversation. An audit without a readable verdict is
**never** taken as a pass. A readable PASS is still the auditor's assessment:
Alkim does not yet run a separate repository-defined verification pipeline.

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
(`Alkim.Workflow.Definition.from_map/1`), with only simple, explicit
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

### Workflow runs

A run's page is laid out like a project's: a header that does not move, then
tabs over what the run is made of.

- **Timeline** — everything that happened, merged and in order.
- **Steps** — the step tree, with advisor consultations nested under the step
  that asked.
- **Agents** — the run seen from *inside*: one pane per agent, with its own
  output, and a picker to switch between them. The implementer opens first
  and is marked *main*, because it is the one a human talks to. Watching it
  receive the advisor's answer is the point: you see the agents talking.
  **Open in the CLI** runs the harness's own interface on that agent's
  conversation, in the run's worktree — but never while the agent is
  mid-turn, because two clients on one conversation is how you corrupt it.
- **Changes** — what the run did in its worktree. A run that works in the
  project folder says so instead, because there its changes cannot be told
  apart from anything else happening there.
- **Roles** — the mapping you chose, and any permission Alkim could not
  actually enforce.

Agents are grouped by **conversation, not by step**: an implementer that
implements and then fixes is one agent with two steps, while each audit round
is a fresh, independent session. The page shows that distinction because it
is the design.

Status and a human checkpoint stay *above* the tabs. They are what a run
needs you for, and must never be hidden behind a tab you did not open.

A limitation worth knowing: a session's activity lives in its process, so an
agent that has finished — an advisor is terminated as soon as it answers —
has nothing left to replay in its pane. The timeline keeps what it said.
Persisting activity is the next step for this (see the roadmap).

### Cloud providers

A **provider profile** runs an installed harness against your own cloud
instead of its default backend. The CLI still runs **locally** — agent loop,
tools, permissions, your files — and only model inference goes to the
provider, which bills it. Alkim only starts the same CLI with the
configuration each CLI documents:

| Harness → provider | Configuration |
|---|---|
| Claude Code → Amazon Bedrock | `CLAUDE_CODE_USE_BEDROCK=1`, `AWS_REGION`, AWS profile / access keys / Bedrock API key, optional `ANTHROPIC_BEDROCK_BASE_URL` |
| Claude Code → Microsoft Foundry | `CLAUDE_CODE_USE_FOUNDRY=1`, `ANTHROPIC_FOUNDRY_RESOURCE` or `…_BASE_URL`, API key or Entra ID (`az login`) |
| Claude Code → Google Vertex AI | `CLAUDE_CODE_USE_VERTEX=1`, `ANTHROPIC_VERTEX_PROJECT_ID`, `CLOUD_ML_REGION`, Application Default Credentials |
| Codex → Azure OpenAI / Foundry | `-c model_provider=…` with the v1 endpoint (`…/openai/v1`, `wire_api = "responses"`); API key through Alkim's adapter |
| Codex → Amazon Bedrock | built-in `amazon-bedrock` provider (`aws.region`, `aws.profile`) or access keys |

Codex is configured with `-c` overrides, so your `~/.codex/config.toml` is
never modified. Create profiles under **Providers**; each then appears as a
harness choice in sessions and per workflow role — e.g. the implementer on
Bedrock and the auditor on Azure OpenAI. **Models** are the provider's
identifiers (Bedrock model/inference-profile IDs or ARNs, Foundry/Azure
deployment names); a profile can carry a default, and Foundry and Codex
profiles need one.

**Provider profiles store credential references, not secret values.**
Credentials entered through Alkim can be stored in macOS Keychain. A profile
records how to obtain them:

| Source | Details |
|---|---|
| Ambient | the provider SDK's own chain: AWS profile/SSO, `az login`, gcloud ADC |
| Environment variable | a variable of Alkim's own process (a `brew services` daemon does not see your shell exports) |
| macOS Keychain — API key | pasted once, written to the Keychain (service `alkim`) through `security -i` on stdin, so it never appears in any process's arguments |
| macOS Keychain — AWS access keys | access key ID, secret and optional session token entered in a form instead of editing `~/.aws/credentials` |

Stored credentials are resolved when work starts and passed to the harness
process environment. Profile records do not contain their values. Terminal
logs capture what a harness prints, so they can contain sensitive output.
*Forget credential* deletes the credential stored in Keychain; **Delete** on
a terminal removes its saved output. When a profile names an AWS profile, inherited
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
| Fake | dev/test | `priv/bin/alkim-fake-harness` |
| Kiro CLI, Copilot CLI, OpenCode, Gemini CLI | detected only | no adapter yet — the UI says so |

An adapter implements `Alkim.Harness`. Adapters are pure modules — they
build argv, parse output lines and declare capabilities; the session process
owns the OS process:

```elixir
@callback id() :: atom()
@callback name() :: String.t()
@callback detect() :: {:ok, %{executable: path, version: String.t() | nil}} | :not_found
@callback capabilities() :: Alkim.Harness.Capabilities.t()
@callback build_command(turn) :: {:ok, %{executable: path, args: [String.t()], env: [...]}} | {:error, term}
@callback parse_output(:stdout | :stderr, line :: String.t()) :: [event]
@callback list_models(executable) :: {:ok, [model]} | :error   # optional
@callback provider_kinds() :: [atom()]                          # optional
@callback build_interactive(session) :: {:ok, launch} | {:error, term} # optional
@callback quit_sequence() :: binary() | nil                     # optional
```

`Capabilities` declares streaming, structured output, resume, stop, model
selection (and whether the model list is closed), permission modes, the
read-only mode and who enforces it. The UI only shows controls an adapter
declares.

**Known limitations, documented rather than faked:**

- Non-interactive runs cannot ask for approval mid-turn. In `acceptEdits`,
  Claude Code cannot run shell commands (verified: an implementer could not
  run `python3`); use `auto` or allowlist commands in your Claude Code
  settings. Alkim never bypasses permissions.
- Codex refuses to run outside a Git repository; Alkim does not pass
  `--skip-git-repo-check`.
- Follow-up messages go between turns, not during a running turn.
- In background sessions, *Stop* signals the harness. Interactive terminals
  use an adapter-defined quit sequence when available, then fall back to
  signals if needed.
- Activity logs live in memory (last 2 000 events, kept 30 minutes after a
  session ends); session and workflow history is persisted.
- Concurrent work in the same directory shares files. Use separate
  [worktrees](#worktrees) for independent tasks. Worktrees separate checkouts;
  the harness's permission mode controls what an agent may access.
- Codex terminal resume falls back to `resume --last` when Alkim has no
  conversation ID. That selects the latest conversation in the workspace,
  which may differ from the terminal you intended to continue.

**Adding an adapter:** implement `Alkim.Harness` in
`lib/alkim/harness/<name>.ex`, add it to `config :alkim,
:harness_adapters`, drop it from `Alkim.Harness.planned/0`, and test
`build_command/1` and `parse_output/2` as pure functions — no real CLI needed
(see `test/alkim/harness/adapters_test.exs`). Take every flag from the
installed CLI's `--help` or its official docs.

## Architecture

```text
             Phoenix LiveView UI  (never spawns processes)
                        │
           ┌────────────┴────────────┐
           ▼                         ▼
   Alkim.Runtime            Alkim.Workflow           public APIs
   (sessions)                 (multi-agent runs)
           │                         │ owns sessions of its roles
           ▼                         ▼
   SessionSupervisor          Workflow.Supervisor        DynamicSupervisors
     └─ SessionServer ◄──────── Workflow.Server
           │  owns one Erlang Port
           ▼
     priv/bin/alkim-exec    POSIX wrapper: stdin from /dev/null, stdout/stderr
           │                  tagged, harness killed if the port closes
           ▼
     claude -p / codex exec   the CLI you installed (optionally → your cloud)

   events ──► EventBus (Phoenix.PubSub) ──► LiveViews     no polling
   state  ──► SQLite (Ecto)                                history, workflows, profiles

   Alkim.Terminals ──► Terminals.Server ──► priv/bin/alkim-pty ──► CLI TUI
                              │                         ▲
                              ├──► bounded disk log     │ resize + keyboard input
                              └──► LiveView / xterm.js ─┘
```

### Supervision tree

```text
Alkim.Application (one_for_one)
├── AlkimWeb.Telemetry
├── Alkim.Repo                          SQLite
├── Ecto.Migrator                         releases migrate on boot
├── Task                                  mark work left active by a previous run
├── Phoenix.PubSub                        transport of Alkim.Runtime.EventBus
├── Alkim.Runtime.Supervisor (rest_for_one)
│   ├── Alkim.Runtime.Registry          session id → pid + summary
│   ├── Alkim.Runtime.SessionSupervisor DynamicSupervisor
│   │   └── SessionServer …               :temporary
│   ├── Alkim.Workflow.Registry
│   ├── Alkim.Workflow.Supervisor       DynamicSupervisor
│   │   └── Workflow.Server …             :temporary
│   ├── Alkim.Terminals.Registry        terminal id → pid
│   ├── Alkim.Terminals.Supervisor      DynamicSupervisor
│   │   └── Terminals.Server …            :temporary, owns one pty helper
│   ├── Alkim.Runtime.CrashMonitor      records crashed sessions and workflows
│   └── Alkim.Harness.Discovery         installed harnesses and their models
└── AlkimWeb.Endpoint
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

Session events (`{:session_event, %Alkim.Runtime.Event{}}`):
`session.started|input|resumed|output|waiting|completed|failed|stopped`, with
output kinds `assistant`, `reasoning`, `tool`, `stdout`, `stderr`, `system`,
`error`, `result`. Workflow events (`{:workflow_event, …}`):
`workflow.started|completed|failed|waiting|stopped|resumed`,
`workflow.iteration.*`, `workflow.step.*`, `advisor.*`, `audit.*`,
`human.requested|answered`.

## Security and trust model

Alkim starts agents that read and write your files, so it assumes **one
trusted local user** and is built to be unreachable by anyone else:

- **Loopback only**, `127.0.0.1` by default, with no authentication: anyone
  who can reach the port can drive your agents. Don't bind it elsewhere
  without real authentication in front.
- **DNS-rebinding protection:** requests whose `Host` is not a loopback name
  are rejected, and LiveView sockets only accept loopback origins, so a web
  page you visit cannot talk to Alkim.
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
  its own family cleared, so a session Alkim starts is never a continuation
  of whatever session happened to launch Alkim.
- **Credential references:** each CLI keeps its own auth; provider profiles
  refer to environment, ambient or Keychain credentials (see [Cloud providers](#cloud-providers)); the
  daemon's own secrets (`SECRET_KEY_BASE`, `RELEASE_COOKIE`, `DATABASE_PATH`)
  are removed from every harness environment.
- **No orphans:** both spawn paths terminate the harness when their port
  closes — on Stop, a crash, or the VM dying. The pty helper signals the
  whole process *group*, so a TUI's own subprocesses go with it, and every
  wait it performs is bounded so it can never hang holding a terminal open.
- **Terminals are argv too:** an embedded terminal runs an adapter-built argv
  on a pseudo-terminal, never a shell. Alkim offers one only for harnesses
  whose interactive mode an adapter declares; the UI cannot ask for an
  arbitrary command.

What Alkim does *not* protect against: the agents themselves. A harness has
whatever power its configuration and the chosen permission mode give it.

## Running as a daemon

Alkim is an OTP release meant to run under `launchd` / `systemd` (and,
later, `brew services`):

```bash
MIX_ENV=prod mix do compile + assets.deploy
MIX_ENV=prod mix release
_build/prod/rel/alkim/bin/alkim start     # foreground; `daemon` to background
```

A release needs no configuration: it migrates its database on boot and keeps
its data — including a generated cookie-signing secret (`0600`) — in
`~/Library/Application Support/Alkim` (macOS), or `$XDG_DATA_HOME/alkim`
with `~/.local/share/alkim` as the Linux fallback.

A daemon does not inherit your shell's `PATH`, so discovery also searches
`~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.npm-global/bin`,
`~/.bun/bin`, `~/.volta/bin` and `~/.cargo/bin`, and harnesses run with that
extended `PATH` (Node-based CLIs need to find `node`).

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `ALKIM_PORT` | `4777` | HTTP port |
| `ALKIM_BIND` | `127.0.0.1` | interface to bind — read [Security](#security-and-trust-model) first |
| `ALKIM_WORKSPACE_ROOTS` | your home directory | colon-separated directories sessions may run in |
| `ALKIM_TURN_TIMEOUT_SECONDS` | none | kill a turn that runs longer than this |
| `ALKIM_TIER_<NAME>` | see `config/config.exs` | default `harness[@profile][:model]` for a workflow tier |
| `ALKIM_EXTRA_PATH` | — | extra directories to search for harness CLIs |
| `ALKIM_<ID>_BIN` | — | pin a binary, e.g. `ALKIM_CLAUDE_BIN=/opt/bin/claude` |
| `ALKIM_ENABLE_FAKE_HARNESS` | `false` in releases | offer the demo harness |
| `ALKIM_DATA_DIR` | see above | database and secret location (releases) |
| `DATABASE_PATH` | per environment | database file (in dev, lets a second instance run alongside) |

Application settings (`config/config.exs`): `harness_adapters`,
`turn_timeout`, `session_retention_ms`, `max_sessions`, `max_workflows`,
`workflow_tiers`. Set `:terminal_log_dir` to override the terminal log
directory (by default, `terminal-logs` beside the database).

## Development

```bash
mix test         # fake harness and in-memory secrets; no agent CLI needed
mix precommit    # compile --warnings-as-errors, unused deps, format, test
mix assets.build # rebuild CSS and JavaScript
```

[CI](.github/workflows/ci.yml) runs the same checks on every push and pull
request, with the versions in `.tool-versions`.

- **The fake harness** (`priv/bin/alkim-fake-harness`) is a real OS process
  driven through the same wrapper and port as Claude Code or Codex, so tests
  exercise the whole runtime — streaming, failures, timeouts, crashes,
  workflows, provider plumbing.
- **Tests never touch your Keychain** (`Alkim.MemorySecrets`) and never run
  a real agent CLI.
- **Real CLI and cloud checks** are separate manual integrations. Agent
  prompts can incur charges through the configured provider.
- Commits follow Conventional Commits: `type(scope): summary`.

```text
lib/alkim/
  runtime.ex workflow.ex terminals.ex       execution APIs
  projects.ex worktrees.ex git.ex           projects, isolation and repository state
  providers.ex                             provider profiles
  runtime/     supervisors, session server, registry, crash monitor, event bus, OS process
  harness/     behaviour helpers, discovery, adapters (claude, codex, fake)
  workflow/    server, definition, presets, roles, protocol, prompts, timeline, store
  terminals/   PTY server, terminal records and bounded output logs
  worktrees/   worktree schema
  providers/   profile schema, secrets behaviour, Keychain backend
  sessions/    session history (Ecto)
  projects/    project schema
  workspace.ex path validation and folder browsing
lib/alkim_web/
  live/        projects, project, sessions, new session/workflow, session,
               workflow, providers
  components/  layouts (shell), session components, workspace picker
  nav.ex       sidebar state, mounted as a hook on every LiveView
  plugs/       loopback-only guard
assets/        UI styles, sidebar interactions and terminal hooks
c_src/         PTY helper source
priv/bin/      alkim-exec, alkim-fake-harness, compiled alkim-pty
```

## Roadmap

Projects, embedded terminals, worktree isolation, provider profiles and the
implement/audit loop are implemented. The next work is about making that
foundation more complete:

- **Distribution and everyday reliability:** finish Homebrew packaging and
  exercise the runtime with real Claude Code and Codex workloads.
- **Durable activity and recovery:** persist detailed session events beyond
  the in-memory window and improve interrupted-conversation recovery.
- **Changes and verification:** add file-level diff browsing, clearer
  attribution to workflow steps, and explicit test/build results alongside
  agent review verdicts.
- **Interactive continuity:** improve terminal resume coverage and the
  transition between background work and taking over in the CLI.
- **More adapters:** implement the detected CLIs only after their execution,
  permissions and resume behaviour are understood and tested.
- **Workflow definitions:** expose reusable definitions and additional roles
  while keeping conditions, iteration limits and human decisions explicit.
- **Cross-harness handoff:** pass a task's objective, changes and remaining
  work to a new harness conversation without treating native conversation
  IDs as portable.

The scope remains a local, single-user tool for coding-agent execution and
coordination. Remote execution, multi-user collaboration, automatic merging,
automatic model selection and a model loop of Alkim's own are outside the
current scope.

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
