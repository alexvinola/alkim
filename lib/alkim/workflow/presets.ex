defmodule Alkim.Workflow.Presets do
  @moduledoc """
  Built-in workflow definitions, written in the same shape a user-provided
  file would use (`Alkim.Workflow.Definition.from_map/1`), so they can
  later become editable configuration.
  """

  alias Alkim.Workflow.Definition

  @presets [
    %{
      name: "simple-coding",
      title: "Simple coding",
      description: "Implement → Done",
      roles: %{implementer: %{tier: :fast}, advisor: %{tier: :reasoning}},
      steps: [%{id: "implement", role: "implementer"}],
      max_iterations: 1
    },
    %{
      name: "coding-with-audit",
      title: "Coding + Audit",
      description: "Implement → Audit → Fix → Re-audit",
      roles: %{
        implementer: %{tier: :fast},
        advisor: %{tier: :reasoning},
        auditor: %{tier: :audit}
      },
      steps: [
        %{id: "implement", role: "implementer"},
        %{id: "audit", role: "auditor"},
        %{id: "fix", role: "implementer", when: "audit.has_findings"},
        %{id: "re_audit", role: "auditor", when: "fix.completed"}
      ],
      repeat: %{from: "fix", while: "re_audit.has_findings"},
      max_iterations: 3
    }
  ]

  @doc "All presets as validated definitions."
  def all do
    Enum.map(@presets, fn preset ->
      {:ok, definition} = Definition.from_map(preset)
      definition
    end)
  end

  def fetch(name) do
    case Enum.find(all(), &(&1.name == name)) do
      nil -> :error
      definition -> {:ok, definition}
    end
  end
end
