defmodule Alkim.Harness do
  @moduledoc """
  Behaviour implemented by every harness adapter (Claude Code, Codex, ...).

  Adapters are deliberately *not* processes. The OS process of a harness is
  owned by a `Alkim.Runtime.SessionServer`, which receives the port messages.
  An adapter only answers three questions:

    1. Is the harness installed, and where? (`c:detect/0`)
    2. Which argv starts a turn? (`c:build_command/1`)
    3. What does a line of output mean? (`c:parse_output/2`)

  plus a static declaration of what it supports (`c:capabilities/0`).

  A *turn* is one run of the harness process. The first turn carries the
  initial prompt; follow-up turns (only when `capabilities().resume` is true)
  resume the harness' own conversation using the reference it reported
  through a `{:harness_ref, ref}` event.
  """

  alias Alkim.Harness.Capabilities

  @doc """
  Environment entries that unset every inherited variable matching
  `prefixes`, except the ones the adapter is setting itself.

  Alkim may well be started from inside an agent's own terminal, and that
  agent exports a whole family of variables — session ids, sockets, tokens,
  "this is a child session" markers. Inheriting them makes the harness
  Alkim starts believe it is a continuation of something else, which
  changes how it behaves and what it persists. Every session must start from
  a clean environment.
  """
  @spec clear_inherited([String.t()], [{String.t(), term()}]) :: [{String.t(), false}]
  def clear_inherited(prefixes, keeping \\ []) do
    kept = MapSet.new(keeping, fn {name, _value} -> name end)

    for {name, _value} <- System.get_env(),
        Enum.any?(prefixes, &String.starts_with?(name, &1)),
        not MapSet.member?(kept, name),
        do: {name, false}
  end

  @type id :: atom()

  @type detection :: %{
          required(:executable) => String.t(),
          optional(:version) => String.t() | nil
        }

  @typedoc """
  An interactive session: the harness's own TUI, on a pseudo-terminal.
  `session_id` is the id Alkim would like the conversation to have — only
  useful where the CLI accepts one. `resume` continues an existing
  conversation, or is `"last"` where the CLI only offers "most recent".
  """
  @type interactive :: %{
          required(:workspace) => String.t(),
          required(:executable) => String.t(),
          required(:model) => String.t() | nil,
          required(:permission_mode) => String.t() | nil,
          required(:resume) => String.t() | nil,
          required(:session_id) => String.t(),
          optional(:provider) => provider() | nil
        }

  @type turn :: %{
          required(:prompt) => String.t(),
          required(:workspace) => String.t(),
          required(:executable) => String.t(),
          required(:model) => String.t() | nil,
          required(:permission_mode) => String.t() | nil,
          required(:resume) => String.t() | nil,
          optional(:session_id) => String.t(),
          optional(:provider) => provider() | nil
        }

  @typedoc """
  A resolved provider profile (see `Alkim.Providers`): where model
  inference goes instead of the harness default. `secret` is only ever
  placed in the harness process environment.
  """
  @type provider :: %{
          kind: atom(),
          settings: %{String.t() => String.t()},
          secret: String.t() | nil,
          name: String.t()
        }

  @typedoc """
  How to start the process. `executable` must be an absolute path and `args`
  a list of plain strings: nothing is ever interpreted by a shell. `env`
  entries are added to (or, with `false`, removed from) the inherited
  environment.
  """
  @type launch :: %{
          required(:executable) => String.t(),
          required(:args) => [String.t()],
          optional(:env) => [{String.t(), String.t() | false}],
          optional(:harness_ref) => String.t()
        }

  @typedoc "A model the harness itself reported. `id` is what is passed to the CLI."
  @type model :: %{id: String.t(), name: String.t(), description: String.t() | nil}

  @typedoc "Normalized events an adapter extracts from harness output."
  @type event ::
          {:message, :assistant | :reasoning, String.t()}
          | {:tool, name :: String.t(), summary :: String.t()}
          | {:output, String.t()}
          | {:stderr, String.t()}
          | {:system, String.t()}
          | {:error, String.t()}
          | {:result, map()}
          | {:harness_ref, String.t()}

  @callback id() :: id()
  @callback name() :: String.t()
  @callback detect() :: {:ok, detection()} | :not_found
  @callback capabilities() :: Capabilities.t()
  @callback build_command(turn()) :: {:ok, launch()} | {:error, term()}
  @callback parse_output(:stdout | :stderr, line :: String.t()) :: [event()]

  @doc """
  Asks the installed CLI which models it offers. Only implement this when the
  CLI exposes that information itself; return `:error` when it cannot be
  obtained. Called by discovery, never on the request path.
  """
  @callback list_models(executable :: String.t()) :: {:ok, [model()]} | :error

  @doc """
  Which argv starts the harness's *interactive* interface, to be run on a
  pseudo-terminal. Only implement it for CLIs whose TUI has been verified;
  Alkim offers no interactive mode for the others rather than guessing.

  When the CLI accepts a caller-chosen conversation id, return it as
  `:harness_ref` in the launch so the terminal can be resumed exactly.
  """
  @callback build_interactive(interactive()) :: {:ok, launch()} | {:error, term()}

  @doc """
  Keystrokes that make the interactive harness quit through its own path,
  or `nil` when none is known.

  It matters: a harness killed by a signal may lose the conversation it was
  holding, while quitting its own way saves it. Only implement this with a
  sequence verified against the real CLI — a wrong one would be typed into
  the user's prompt.
  """
  @callback quit_sequence() :: binary() | nil

  @doc "Provider kinds (`Alkim.Providers.Profile`) this adapter can target."
  @callback provider_kinds() :: [atom()]

  @optional_callbacks list_models: 1, provider_kinds: 0, build_interactive: 1, quit_sequence: 0

  @doc "Adapters enabled in this installation (see `config :alkim, :harness_adapters`)."
  @spec adapters() :: [module()]
  def adapters, do: Application.get_env(:alkim, :harness_adapters, [])

  @doc """
  Harnesses Alkim knows about but has no adapter for yet. Discovery still
  reports whether they are installed so the UI can say so honestly.
  """
  @spec planned() :: [%{id: id(), name: String.t(), executable: String.t()}]
  def planned do
    [
      %{id: :kiro, name: "Kiro CLI", executable: "kiro-cli"},
      %{id: :copilot, name: "GitHub Copilot CLI", executable: "copilot"},
      %{id: :opencode, name: "OpenCode", executable: "opencode"},
      %{id: :gemini, name: "Gemini CLI", executable: "gemini"}
    ]
  end

  @doc "Finds the adapter module for a harness id (atom or string)."
  @spec fetch_adapter(id() | String.t()) :: {:ok, module()} | :error
  def fetch_adapter(id) when is_binary(id) do
    Enum.find_value(adapters(), :error, fn adapter ->
      if Atom.to_string(adapter.id()) == id, do: {:ok, adapter}
    end)
  end

  def fetch_adapter(id) when is_atom(id) do
    Enum.find_value(adapters(), :error, fn adapter ->
      if adapter.id() == id, do: {:ok, adapter}
    end)
  end
end
