defmodule Khymeia.Workflow.Role do
  @moduledoc """
  A role in a workflow, and its assignment to a concrete harness/model.

  A role is *not* a model. The workflow engine only knows role ids and their
  **kind**, which decides how Khymeia treats the step:

    * `:implementer` — works in the workspace (write access); can ask for a
      consultation or for human input; its conversation is resumed for fixes.
    * `:reviewer`    — independent, read-only; must return an audit verdict.
    * `:consultant`  — ephemeral, read-only; answers one question.

  Built-in roles: `implementer`, `advisor`, `auditor`. Future roles such as
  `security_reviewer`, `test_reviewer` (reviewers), `planner`, `architect`
  (consultants) or `debugger` (implementer) only need an entry in `@roles`.

  Which harness and model play a role comes from the user's choice, with
  defaults from *capability tiers* (`fast`, `reasoning`, `audit`), configured
  in `config :khymeia, :workflow_tiers` or `KHYMEIA_TIER_<NAME>=harness[:model]`.
  Khymeia never decides which model is "better".
  """

  alias Khymeia.Harness.Capabilities

  @roles %{
    implementer: %{
      kind: :implementer,
      title: "Implementer",
      permissions: %{read: true, write: true}
    },
    advisor: %{kind: :consultant, title: "Advisor", permissions: %{read: true, write: false}},
    auditor: %{kind: :reviewer, title: "Auditor", permissions: %{read: true, write: false}}
  }

  @type id :: :implementer | :advisor | :auditor
  @type kind :: :implementer | :reviewer | :consultant

  @enforce_keys [:id, :harness]
  defstruct [
    :id,
    :harness,
    :model,
    :permission_mode,
    :tier,
    permissions: %{read: true, write: false},
    enforcement: :none
  ]

  @type t :: %__MODULE__{
          id: id(),
          harness: atom(),
          model: String.t() | nil,
          permission_mode: String.t() | nil,
          tier: atom() | nil,
          permissions: %{read: boolean(), write: boolean()},
          enforcement: :sandbox | :harness | :none | :not_applicable
        }

  @order [:implementer, :advisor, :auditor]

  @doc "Role ids in display order."
  def ids, do: @order ++ (Map.keys(@roles) -- @order)
  def kind(id), do: @roles[id].kind
  def title(id), do: @roles[id].title
  def permissions(id), do: @roles[id].permissions

  def parse_id(id) when is_atom(id) and is_map_key(@roles, id), do: {:ok, id}

  def parse_id(id) when is_binary(id) do
    case Enum.find(ids(), &(Atom.to_string(&1) == id)) do
      nil -> {:error, "unknown role #{inspect(id)}"}
      role -> {:ok, role}
    end
  end

  def parse_id(id), do: {:error, "unknown role #{inspect(id)}"}

  @doc """
  Builds an assignment and resolves its permission mode.

  Read-only roles get the adapter's read-only mode and record who enforces
  it. When the harness has none, the permission is recorded as `:none`: the
  workflow still runs, but the UI states that read-only is not guaranteed.
  Writing roles use the mode the user picked, or the adapter's write mode.
  """
  @spec assign(id(), atom(), String.t() | nil, String.t() | nil, Capabilities.t(), atom() | nil) ::
          t()
  def assign(id, harness, model, permission_mode, %Capabilities{} = caps, tier \\ nil) do
    permissions = permissions(id)

    {mode, enforcement} =
      if permissions.write do
        {permission_mode || caps.write_mode, :not_applicable}
      else
        case caps.read_only_mode do
          nil -> {nil, :none}
          mode -> {mode, caps.read_only_enforcement}
        end
      end

    %__MODULE__{
      id: id,
      harness: harness,
      model: model,
      permission_mode: mode,
      tier: tier,
      permissions: permissions,
      enforcement: enforcement
    }
  end

  @doc "Human description of how (or whether) read-only is enforced."
  def enforcement_note(%__MODULE__{enforcement: :sandbox}),
    do: "read-only · enforced by an OS sandbox"

  def enforcement_note(%__MODULE__{enforcement: :harness}),
    do: "read-only · enforced by the harness"

  def enforcement_note(%__MODULE__{enforcement: :none}),
    do: "read-only NOT guaranteed: this harness has no read-only mode"

  def enforcement_note(%__MODULE__{permission_mode: nil}),
    do: "writes · harness default permissions"

  def enforcement_note(%__MODULE__{permission_mode: mode}), do: "writes · #{mode}"

  def to_map(%__MODULE__{} = r) do
    %{
      "harness" => Atom.to_string(r.harness),
      "model" => r.model,
      "permission_mode" => r.permission_mode,
      "tier" => r.tier && Atom.to_string(r.tier),
      "write" => r.permissions.write,
      "enforcement" => Atom.to_string(r.enforcement)
    }
  end

  ## Tiers

  @doc "Configured tiers: `%{tier => %{harness: atom, model: String.t() | nil}}`."
  def tiers, do: Application.get_env(:khymeia, :workflow_tiers, %{})

  @doc """
  Default harness/model for a tier, restricted to available harnesses. Falls
  back to the first available harness with the model left to the harness.
  """
  def default_for(tier, available_harness_ids) do
    case Map.get(tiers(), tier) do
      %{harness: harness} = spec ->
        if harness in available_harness_ids,
          do: %{harness: harness, model: spec[:model]},
          else: fallback(available_harness_ids)

      _ ->
        fallback(available_harness_ids)
    end
  end

  defp fallback([first | _]), do: %{harness: first, model: nil}
  defp fallback([]), do: %{harness: nil, model: nil}
end
