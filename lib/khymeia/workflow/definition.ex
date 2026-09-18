defmodule Khymeia.Workflow.Definition do
  @moduledoc """
  A declarative workflow: which roles it uses, which steps run in which
  order, and the only control flow it supports — simple, explicit conditions
  and one bounded repeat.

      name: coding-with-audit
      roles:
        implementer: {tier: fast}
        advisor:     {tier: reasoning}
        auditor:     {tier: audit}
      steps:
        - {id: implement, role: implementer}
        - {id: audit,     role: auditor}
        - {id: fix,       role: implementer, when: audit.has_findings}
        - {id: re_audit,  role: auditor,     when: fix.completed}
      repeat: {from: fix, while: re_audit.has_findings}
      max_iterations: 3
      advisor: {max_calls: 3, allowed_reasons: [architecture, security, ...]}

  Conditions are `<step id>.<predicate>` evaluated against the latest result
  of that step, with predicates `completed`, `failed`, `passed` and
  `has_findings`. There is no expression language on purpose.

  `from_map/1` accepts exactly that shape (string or atom keys), so a YAML or
  JSON loader can feed it later without changing the engine.
  """

  alias Khymeia.Workflow.Role

  @predicates ~w(completed failed passed has_findings)a

  defmodule Step do
    @moduledoc "One step of a definition."
    @enforce_keys [:id, :role]
    defstruct [:id, :role, when: nil]

    @type condition :: {step_id :: String.t(), :completed | :failed | :passed | :has_findings}
    @type t :: %__MODULE__{
            id: String.t(),
            role: Khymeia.Workflow.Role.id(),
            when: condition() | nil
          }
  end

  @enforce_keys [:name, :steps]
  defstruct [
    :name,
    :title,
    :description,
    steps: [],
    roles: %{},
    repeat: nil,
    max_iterations: 3,
    advisor: %{
      max_calls: 3,
      allowed_reasons: ~w(architecture security unclear_requirement repeated_failure)
    }
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          title: String.t() | nil,
          description: String.t() | nil,
          steps: [Step.t()],
          roles: %{Role.id() => %{tier: atom()}},
          repeat: %{from: String.t(), while: Step.condition()} | nil,
          max_iterations: pos_integer(),
          advisor: %{max_calls: non_neg_integer(), allowed_reasons: [String.t()]}
        }

  @doc "Builds and validates a definition from a plain map."
  @spec from_map(map()) :: {:ok, t()} | {:error, String.t()}
  def from_map(map) do
    get = fn m, key, default -> Map.get(m, key, Map.get(m, Atom.to_string(key), default)) end

    with {:ok, steps} <- parse_steps(get.(map, :steps, [])),
         {:ok, roles} <- parse_roles(get.(map, :roles, %{})),
         {:ok, repeat} <- parse_repeat(get.(map, :repeat, nil)),
         advisor = get.(map, :advisor, %{}) do
      definition = %__MODULE__{
        name: to_string(get.(map, :name, "workflow")),
        title: get.(map, :title, nil),
        description: get.(map, :description, nil),
        steps: steps,
        roles: roles,
        repeat: repeat,
        max_iterations: get.(map, :max_iterations, 3),
        advisor: %{
          max_calls: get.(advisor, :max_calls, 3),
          allowed_reasons:
            advisor
            |> get.(
              :allowed_reasons,
              ~w(architecture security unclear_requirement repeated_failure)
            )
            |> Enum.map(&to_string/1)
        }
      }

      validate(definition)
    end
  end

  @doc "Serializable form, persisted with each run (and accepted by `from_map/1`)."
  def to_map(%__MODULE__{} = d) do
    %{
      "name" => d.name,
      "title" => d.title,
      "description" => d.description,
      "steps" =>
        Enum.map(d.steps, fn s ->
          %{"id" => s.id, "role" => Atom.to_string(s.role), "when" => condition_to_string(s.when)}
        end),
      "roles" =>
        Map.new(d.roles, fn {role, spec} ->
          {Atom.to_string(role), %{"tier" => to_string(spec.tier)}}
        end),
      "repeat" =>
        d.repeat && %{"from" => d.repeat.from, "while" => condition_to_string(d.repeat.while)},
      "max_iterations" => d.max_iterations,
      "advisor" => %{
        "max_calls" => d.advisor.max_calls,
        "allowed_reasons" => d.advisor.allowed_reasons
      }
    }
  end

  @doc "Roles the steps need, plus the advisor when declared — in display order."
  def roles_used(%__MODULE__{} = d) do
    used = MapSet.new(Enum.map(d.steps, & &1.role))
    used = if Map.has_key?(d.roles, :advisor), do: MapSet.put(used, :advisor), else: used
    Enum.filter(Role.ids(), &MapSet.member?(used, &1))
  end

  @doc "Evaluates a condition against `results` (step id → latest outcome)."
  def holds?(nil, _results), do: true

  def holds?({step_id, predicate}, results) do
    case Map.get(results, step_id) do
      nil -> false
      outcome -> predicate in outcome
    end
  end

  def condition_to_string(nil), do: nil
  def condition_to_string({step, predicate}), do: "#{step}.#{predicate}"

  ## Parsing

  defp parse_steps(steps) when is_list(steps) and steps != [] do
    Enum.reduce_while(steps, {:ok, []}, fn step, {:ok, acc} ->
      get = fn key -> Map.get(step, key, Map.get(step, Atom.to_string(key))) end

      with {:ok, role} <- Role.parse_id(get.(:role)),
           {:ok, condition} <- parse_condition(get.(:when)),
           id when is_binary(id) or is_atom(id) <- get.(:id) do
        {:cont, {:ok, acc ++ [%Step{id: to_string(id), role: role, when: condition}]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
        _ -> {:halt, {:error, "every step needs an id"}}
      end
    end)
  end

  defp parse_steps(_), do: {:error, "a workflow needs at least one step"}

  defp parse_roles(roles) when is_map(roles) do
    Enum.reduce_while(roles, {:ok, %{}}, fn {role, spec}, {:ok, acc} ->
      tier = Map.get(spec || %{}, :tier, Map.get(spec || %{}, "tier"))

      case Role.parse_id(role) do
        {:ok, role} ->
          {:cont, {:ok, Map.put(acc, role, %{tier: tier && to_existing_or_nil(tier)})}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp parse_roles(_), do: {:error, "roles must be a map"}

  defp parse_repeat(nil), do: {:ok, nil}

  defp parse_repeat(repeat) do
    from = Map.get(repeat, :from, Map.get(repeat, "from"))

    with {:ok, condition} when not is_nil(condition) <-
           parse_condition(Map.get(repeat, :while, Map.get(repeat, "while"))) do
      {:ok, %{from: to_string(from), while: condition}}
    else
      _ -> {:error, "repeat needs `from` and `while`"}
    end
  end

  defp parse_condition(nil), do: {:ok, nil}

  defp parse_condition(text) when is_binary(text) do
    with [step, predicate] <- String.split(text, ".", parts: 2),
         predicate when predicate in @predicates <- to_existing_or_nil(predicate) do
      {:ok, {step, predicate}}
    else
      _ ->
        {:error,
         "unsupported condition #{inspect(text)} (use <step>.#{Enum.join(@predicates, "|")})"}
    end
  end

  defp parse_condition(other), do: {:error, "unsupported condition #{inspect(other)}"}

  defp validate(%__MODULE__{} = d) do
    ids = Enum.map(d.steps, & &1.id)

    referenced =
      Enum.flat_map(d.steps, fn s -> if s.when, do: [elem(s.when, 0)], else: [] end) ++
        if(d.repeat, do: [d.repeat.from, elem(d.repeat.while, 0)], else: [])

    cond do
      length(Enum.uniq(ids)) != length(ids) ->
        {:error, "step ids must be unique"}

      (unknown = Enum.reject(referenced, &(&1 in ids))) != [] ->
        {:error, "unknown step #{hd(unknown)} in a condition"}

      not (is_integer(d.max_iterations) and d.max_iterations > 0) ->
        {:error, "max_iterations must be > 0"}

      true ->
        {:ok, d}
    end
  end

  defp to_existing_or_nil(value) when is_atom(value), do: value

  defp to_existing_or_nil(value) do
    String.to_existing_atom(to_string(value))
  rescue
    ArgumentError -> nil
  end
end
