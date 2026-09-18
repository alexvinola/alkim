defmodule Khymeia.Runtime.Event do
  @moduledoc """
  Something that happened in a session.

  `seq` increases monotonically within a session, which lets a subscriber
  that also fetched a snapshot drop events it has already seen. Events the
  runtime emits on behalf of a dead session (a crash) carry `seq: nil`.

  Types and their public names:

    | type         | name                | data                                  |
    |--------------|---------------------|---------------------------------------|
    | `:started`   | `session.started`   | `%{os_pid}`                           |
    | `:input`     | `session.input`     | `%{text}` — a message from the user   |
    | `:resumed`   | `session.resumed`   | `%{os_pid, turn}` — follow-up turn    |
    | `:output`    | `session.output`    | `%{kind, text}` (see below)           |
    | `:waiting`   | `session.waiting`   | `%{}` — turn done, can take a message |
    | `:completed` | `session.completed` | `%{exit_code}`                        |
    | `:failed`    | `session.failed`    | `%{exit_code, error}`                 |
    | `:stopped`   | `session.stopped`   | `%{}`                                 |

  Output kinds: `:assistant`, `:reasoning`, `:tool`, `:stdout`, `:stderr`,
  `:system`, `:error`, `:result`.

  The `role` of an event (`:user`, `:harness`, `:runtime`) is what a future
  multi-harness conversation view will group by.
  """

  @enforce_keys [:session_id, :seq, :type, :at]
  defstruct [:session_id, :seq, :type, :at, data: %{}]

  @type type ::
          :started | :input | :resumed | :output | :waiting | :completed | :failed | :stopped

  @type t :: %__MODULE__{
          session_id: String.t(),
          seq: non_neg_integer() | nil,
          type: type(),
          at: DateTime.t(),
          data: map()
        }

  @lifecycle [:started, :resumed, :waiting, :completed, :failed, :stopped]

  def new(session_id, seq, type, data \\ %{}) do
    %__MODULE__{
      session_id: session_id,
      seq: seq,
      type: type,
      at: DateTime.utc_now(),
      data: data
    }
  end

  @doc "The dotted public name, e.g. `\"session.started\"`."
  def name(%__MODULE__{type: type}), do: "session.#{type}"

  def lifecycle?(%__MODULE__{type: type}), do: type in @lifecycle

  def role(%__MODULE__{type: :input}), do: :user
  def role(%__MODULE__{type: :output}), do: :harness
  def role(%__MODULE__{}), do: :runtime
end
