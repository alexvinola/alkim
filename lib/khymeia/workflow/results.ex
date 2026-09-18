defmodule Khymeia.Workflow.StepResult do
  @moduledoc """
  Normalized outcome of an implementer (or consultant) step.

  `changed_files` comes from comparing git snapshots of the workspace before
  and after the step (see `Khymeia.Workflow.Git`); it is `nil` when the
  workspace is not a git repository — Khymeia does not guess.
  """
  defstruct status: :completed, summary: "", changed_files: nil, metadata: %{}

  @type t :: %__MODULE__{
          status: :completed | :failed,
          summary: String.t(),
          changed_files: [String.t()] | nil,
          metadata: map()
        }
end

defmodule Khymeia.Workflow.Finding do
  @moduledoc "One issue reported by a reviewer."
  @severities [:critical, :high, :medium, :low]
  defstruct [:title, :description, :file, :line, severity: :medium]

  @type t :: %__MODULE__{
          severity: :critical | :high | :medium | :low,
          title: String.t(),
          description: String.t() | nil,
          file: String.t() | nil,
          line: pos_integer() | nil
        }

  def severities, do: @severities

  def from_map(%{} = m) do
    %__MODULE__{
      severity: severity(m["severity"]),
      title: to_string(m["title"] || "Untitled finding"),
      description: m["description"] && to_string(m["description"]),
      file: m["file"] && to_string(m["file"]),
      line: if(is_integer(m["line"]) and m["line"] > 0, do: m["line"])
    }
  end

  def to_map(%__MODULE__{} = f),
    do: %{
      "severity" => Atom.to_string(f.severity),
      "title" => f.title,
      "description" => f.description,
      "file" => f.file,
      "line" => f.line
    }

  defp severity(value) do
    Enum.find(@severities, :medium, &(Atom.to_string(&1) == String.downcase(to_string(value))))
  end
end

defmodule Khymeia.Workflow.AuditResult do
  @moduledoc """
  A reviewer's verdict. `:unparseable` means the reviewer did not return a
  verdict Khymeia could read; the workflow then asks a human instead of
  assuming anything.
  """
  alias Khymeia.Workflow.Finding

  defstruct status: :passed, findings: [], raw: nil

  @type t :: %__MODULE__{
          status: :passed | :findings | :unparseable,
          findings: [Finding.t()],
          raw: String.t() | nil
        }

  def to_map(%__MODULE__{} = a),
    do: %{
      "status" => Atom.to_string(a.status),
      "findings" => Enum.map(a.findings, &Finding.to_map/1)
    }

  def from_map(nil), do: nil

  def from_map(%{"status" => status} = m) do
    %__MODULE__{
      status: String.to_existing_atom(status),
      findings: Enum.map(m["findings"] || [], &Finding.from_map/1)
    }
  end
end
