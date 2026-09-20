defmodule Khymeia.Session do
  @moduledoc """
  Runtime snapshot of a session, as returned by `Khymeia.Runtime`.

  The authoritative copy lives inside the session's own process
  (`Khymeia.Runtime.SessionServer`); this struct is just data handed out to
  callers. Persistent history lives in `Khymeia.Sessions.SessionRecord`.

  Status lifecycle:

      starting ──► running ──► completed        (exit 0, not resumable)
                     │   └───► waiting ──► running ...  (exit 0, resumable)
                     ├───────► failed           (non-zero exit, timeout, crash)
                     └───────► stopped          (user request)

  `waiting` means the harness finished its turn and the conversation can be
  continued with a message.
  """

  @type status :: :starting | :running | :waiting | :completed | :failed | :stopped

  @type t :: %__MODULE__{
          id: String.t(),
          harness: atom(),
          workspace: String.t(),
          project_id: String.t() | nil,
          prompt: String.t(),
          model: String.t() | nil,
          permission_mode: String.t() | nil,
          status: status(),
          pid: pid() | nil,
          os_pid: non_neg_integer() | nil,
          harness_ref: String.t() | nil,
          turns: non_neg_integer(),
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          exit_code: integer() | nil,
          error: String.t() | nil,
          metadata: map()
        }

  @enforce_keys [:id, :harness, :workspace, :prompt]
  defstruct [
    :id,
    :harness,
    :workspace,
    :project_id,
    :prompt,
    :model,
    :permission_mode,
    :pid,
    :os_pid,
    :harness_ref,
    :started_at,
    :completed_at,
    :exit_code,
    :error,
    status: :starting,
    turns: 0,
    metadata: %{}
  ]

  @statuses [:starting, :running, :waiting, :completed, :failed, :stopped]
  @terminal [:completed, :failed, :stopped]

  def statuses, do: @statuses
  def terminal_statuses, do: @terminal
  def terminal?(%__MODULE__{status: status}), do: status in @terminal
  def terminal?(status) when is_atom(status), do: status in @terminal

  @doc "A short human label derived from the prompt, e.g. for lists."
  def title(%{prompt: prompt}) do
    prompt
    |> String.split("\n", trim: true)
    |> List.first("")
    |> String.slice(0, 60)
  end
end
