defmodule Khymeia.Harness.Capabilities do
  @moduledoc """
  What an adapter can do. The runtime and the UI consult this instead of
  assuming every harness behaves the same.

    * `:streaming` — output arrives incrementally while the turn runs.
    * `:structured_output` — output is machine-readable (e.g. JSONL events).
    * `:programmatic_mode` — the CLI has a documented non-interactive mode.
    * `:resume` — a finished turn can be continued with a follow-up message.
    * `:stop` — a running turn can be interrupted.
    * `:model_selection` — a model can be passed on the command line.
    * `:models` — a fixed, closed list of models, or `:unknown` when the CLI
      accepts free-form model names. Adapters never guess model lists; the
      ones a CLI reports at runtime come from the optional
      `c:Khymeia.Harness.list_models/1` and are cached by discovery.
    * `:permission_modes` — values the adapter accepts for its
      permission/sandbox option, as `{value, label}`. Empty means the harness
      configuration decides.
    * `:read_only_mode` — the permission mode that prevents the harness from
      modifying the workspace, if it has one, and `:read_only_enforcement`:
      who enforces it — `:sandbox` (an OS-level sandbox), `:harness` (the
      CLI's own permission system) or `:none` (Khymeia cannot guarantee it).
    * `:write_mode` — the mode that lets an agent edit files unattended.
  """

  @type t :: %__MODULE__{
          streaming: boolean(),
          structured_output: boolean(),
          programmatic_mode: boolean(),
          resume: boolean(),
          stop: boolean(),
          model_selection: boolean(),
          models: :unknown | [String.t()],
          permission_modes: [{String.t(), String.t()}],
          read_only_mode: String.t() | nil,
          read_only_enforcement: :sandbox | :harness | :none,
          write_mode: String.t() | nil
        }

  defstruct streaming: false,
            structured_output: false,
            programmatic_mode: false,
            resume: false,
            stop: true,
            model_selection: false,
            models: :unknown,
            permission_modes: [],
            read_only_mode: nil,
            read_only_enforcement: :none,
            write_mode: nil

  @doc "Whether follow-up messages can be sent to a finished turn."
  def send_message?(%__MODULE__{resume: resume}), do: resume
end
