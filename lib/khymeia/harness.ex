defmodule Khymeia.Harness do
  @moduledoc """
  Behaviour implemented by every harness adapter (Claude Code, Codex, ...).

  Adapters are deliberately *not* processes. The OS process of a harness is
  owned by a `Khymeia.Runtime.SessionServer`, which receives the port messages.
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

  alias Khymeia.Harness.Capabilities

  @type id :: atom()

  @type detection :: %{
          required(:executable) => String.t(),
          optional(:version) => String.t() | nil
        }

  @type turn :: %{
          required(:prompt) => String.t(),
          required(:workspace) => String.t(),
          required(:executable) => String.t(),
          required(:model) => String.t() | nil,
          required(:permission_mode) => String.t() | nil,
          required(:resume) => String.t() | nil
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
          optional(:env) => [{String.t(), String.t() | false}]
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

  @optional_callbacks list_models: 1

  @doc "Adapters enabled in this installation (see `config :khymeia, :harness_adapters`)."
  @spec adapters() :: [module()]
  def adapters, do: Application.get_env(:khymeia, :harness_adapters, [])

  @doc """
  Harnesses Khymeia knows about but has no adapter for yet. Discovery still
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
