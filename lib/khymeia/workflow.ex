defmodule Khymeia.Workflow do
  @moduledoc """
  Public API of the workflow runtime: multi-agent runs where configurable
  *roles* (implementer, advisor, auditor) are played by locally installed
  harnesses.

  Khymeia does not decide which agent is better. The user maps
  `role → harness/model` (with capability-tier defaults); Khymeia handles
  execution, coordination, state, handoffs, supervision and observability;
  the harnesses do the reasoning, coding and tool use.

  Everything goes through `Khymeia.Runtime`: no harness ever invokes another
  one directly.
  """

  alias Khymeia.{Runtime, Workspace}
  alias Khymeia.Harness.Discovery
  alias Khymeia.Runtime.EventBus
  alias Khymeia.Workflow.{Definition, Presets, Role, Run, Store}

  @max_iterations_limit 10

  defdelegate presets, to: Presets, as: :all
  defdelegate subscribe(id), to: EventBus, as: :subscribe_workflow
  defdelegate subscribe_all, to: EventBus, as: :subscribe_workflows

  @doc """
  Validates and starts a run.

  `attrs` (string or atom keys):

    * `workflow` — preset name (default `"coding-with-audit"`), or
      `definition` — a map accepted by `Khymeia.Workflow.Definition.from_map/1`;
    * `workspace`, `task`, optional `constraints`;
    * `max_iterations` — overrides the definition's;
    * `roles` — `%{"implementer" => %{"harness" => "claude", "model" => nil,
      "permission_mode" => nil}, ...}`. Missing roles take their tier
      default; an advisor with harness `""`/`"none"` disables consultations.

  Options: `:turn_timeout` for every agent turn.
  """
  @spec start(map(), keyword()) :: {:ok, Run.t()} | {:error, {:invalid, map()} | term()}
  def start(attrs, opts \\ []) do
    attrs = stringify(attrs)

    with {:ok, definition} <- definition(attrs),
         {:ok, workspace, task} <- workspace_and_task(attrs),
         {:ok, max_iterations} <- max_iterations(attrs, definition),
         {:ok, roles, notes} <- assign_roles(attrs, definition, workspace, task) do
      run = %Run{
        id: Ecto.UUID.generate(),
        name: definition.name,
        title: definition.title,
        workspace: workspace,
        task: task,
        constraints: blank_to_nil(attrs["constraints"]),
        status: :pending,
        max_iterations: max_iterations,
        definition: Definition.to_map(definition),
        roles: Map.new(roles, fn {id, role} -> {Atom.to_string(id), Role.to_map(role)} end),
        metadata: %{"limitations" => notes}
      }

      with {:ok, run} <- Store.insert_run(run),
           {:ok, _pid} <-
             Khymeia.Workflow.Supervisor.start_workflow(
               [run: run, definition: definition, roles: roles] ++
                 Keyword.take(opts, [:turn_timeout])
             ) do
        {:ok, run}
      end
    end
  end

  @doc "Stops a run and every agent it started."
  def stop(id), do: call(id, :stop)

  @doc """
  Continues a run that is `waiting` for a human: answers a clarification
  (`%{reply: text}`), retries a failed step, or grants one more iteration.
  """
  def resume(id, params \\ %{}),
    do: call(id, {:resume, Map.new(params, fn {k, v} -> {to_atom_key(k), v} end)})

  @doc "Accepts a waiting run as done."
  def complete(id), do: call(id, :complete)

  @doc """
  Consults a consultant role (`:advisor`) on behalf of a run. Khymeia
  resolves the role to its harness/model, starts an ephemeral supervised
  session, collects the answer and terminates the session.

      Workflow.ask(id, :advisor, %{type: :architecture_question, question: "..."})

  Subject to the run's escalation policy (`max_calls`, `allowed_reasons`).
  """
  def ask(id, role, %{question: _} = request, timeout \\ :timer.minutes(15)) do
    with {:ok, role} <- Role.parse_id(role), do: call(id, {:ask, role, request}, timeout)
  end

  @doc "A run and its steps, from the store (works for finished and interrupted runs)."
  @spec get(String.t()) :: {:ok, Run.t(), [Khymeia.Workflow.Step.t()]} | :error
  def get(id) do
    case Store.get_run(id) do
      nil -> :error
      run -> {:ok, run, Store.steps(run.id)}
    end
  end

  def list_recent(limit \\ 20), do: Store.list_recent(limit)

  @doc "Whether a run still has a live process."
  def alive?(id), do: Registry.lookup(Khymeia.Workflow.Registry, id) != []

  @doc """
  Default role assignments for a definition, restricted to available
  harnesses: `%{role => %{harness: atom | nil, model: String.t() | nil}}`.
  """
  def default_roles(%Definition{} = definition) do
    available = for %{status: :available, id: id} <- Discovery.list(), do: id

    Map.new(Definition.roles_used(definition), fn role ->
      tier = get_in(definition.roles, [role, :tier])
      {role, Role.default_for(tier, available)}
    end)
  end

  ## Validation

  defp definition(%{"definition" => map}) when is_map(map) do
    case Definition.from_map(map) do
      {:ok, d} -> {:ok, d}
      {:error, why} -> invalid(:workflow, why)
    end
  end

  defp definition(attrs) do
    case Presets.fetch(attrs["workflow"] || "coding-with-audit") do
      {:ok, d} -> {:ok, d}
      :error -> invalid(:workflow, "unknown workflow")
    end
  end

  defp workspace_and_task(attrs) do
    case {workspace(attrs), task(attrs)} do
      {{:ok, workspace}, {:ok, task}} -> {:ok, workspace, task}
      {w, t} -> {:error, {:invalid, Map.merge(errors_of(w), errors_of(t))}}
    end
  end

  defp errors_of({:error, {:invalid, errors}}), do: errors
  defp errors_of(_), do: %{}

  defp workspace(attrs) do
    case Workspace.validate(attrs["workspace"]) do
      {:ok, path} -> {:ok, path}
      {:error, reason} -> invalid(:workspace, Workspace.error_message(reason))
    end
  end

  defp task(attrs) do
    case attrs["task"] |> to_string() |> String.trim() do
      "" -> invalid(:task, "describe the task")
      task -> {:ok, task}
    end
  end

  defp max_iterations(attrs, definition) do
    case attrs["max_iterations"] do
      nil ->
        {:ok, definition.max_iterations}

      "" ->
        {:ok, definition.max_iterations}

      n when is_integer(n) and n in 1..@max_iterations_limit ->
        {:ok, n}

      n when is_binary(n) ->
        n
        |> Integer.parse()
        |> then(&max_iterations(%{"max_iterations" => elem(&1 || {0, ""}, 0)}, definition))

      _ ->
        invalid(:max_iterations, "between 1 and #{@max_iterations_limit}")
    end
  end

  defp assign_roles(attrs, definition, workspace, task) do
    requested = stringify(attrs["roles"] || %{})
    defaults = default_roles(definition)

    {roles, errors, notes} =
      Enum.reduce(Definition.roles_used(definition), {%{}, %{}, []}, fn role_id,
                                                                        {roles, errors, notes} ->
        spec = stringify(requested[Atom.to_string(role_id)] || %{})
        default = defaults[role_id]
        harness = if Map.has_key?(spec, "harness"), do: spec["harness"], else: default.choice

        model =
          if Map.has_key?(spec, "model"), do: blank_to_nil(spec["model"]), else: default.model

        case assign_role(
               role_id,
               harness,
               model,
               blank_to_nil(spec["permission_mode"]),
               definition,
               workspace,
               task
             ) do
          :disabled -> {roles, errors, notes ++ ["#{role_id}: disabled"]}
          {:ok, role, note} -> {Map.put(roles, role_id, role), errors, notes ++ List.wrap(note)}
          {:error, message} -> {roles, Map.put(errors, :"role_#{role_id}", message), notes}
        end
      end)

    cond do
      errors != %{} -> {:error, {:invalid, errors}}
      true -> {:ok, roles, notes ++ advisor_note(roles)}
    end
  end

  defp assign_role(:advisor, harness, _model, _mode, _definition, _ws, _task)
       when harness in [nil, "", "none"],
       do: :disabled

  defp assign_role(role_id, nil, _model, _mode, _definition, _ws, _task),
    do: {:error, "no installed harness can play the #{role_id} role"}

  defp assign_role(role_id, choice, model, mode, definition, workspace, task) do
    {harness, profile_id} = Khymeia.Providers.parse_choice(choice)

    with {:ok, adapter} <- Khymeia.Harness.fetch_adapter(to_string(harness)),
         {:ok, available} <- Discovery.fetch_available(adapter.id()) do
      tier = get_in(definition.roles, [role_id, :tier])
      role = Role.assign(role_id, available.id, model, mode, available.capabilities, tier)

      request = %{
        harness: to_string(choice),
        workspace: workspace,
        prompt: task,
        model: role.model,
        permission_mode: role.permission_mode
      }

      case Runtime.validate_request(request) do
        {:ok, params} ->
          # A provider profile may supply the model (e.g. a deployment name).
          role = %{
            role
            | model: params.model,
              profile_id: profile_id && params.profile.id,
              provider: params.profile && Khymeia.Providers.Profile.label(params.profile)
          }

          note =
            if role.enforcement == :none,
              do:
                "#{role_id}: #{available.name} has no read-only mode; Khymeia cannot guarantee it will not modify files"

          {:ok, role, note}

        {:error, {:invalid, errors}} ->
          {:error, errors |> Map.values() |> Enum.join("; ")}
      end
    else
      _ -> {:error, "#{harness} is not an available harness"}
    end
  end

  defp advisor_note(%{advisor: _, implementer: %Role{harness: harness}}) do
    {:ok, adapter} = Khymeia.Harness.fetch_adapter(harness)

    if adapter.capabilities().resume,
      do: [],
      else: [
        "advisor: the implementer harness cannot resume a conversation, so it cannot receive answers"
      ]
  end

  defp advisor_note(_), do: []

  ## Helpers

  defp call(id, message, timeout \\ 15_000) do
    GenServer.call(Khymeia.Workflow.Server.via(id), message, timeout)
  catch
    :exit, {:noproc, _} -> {:error, :not_running}
    :exit, {{:shutdown, _}, _} -> {:error, :not_running}
    :exit, {:normal, _} -> {:error, :not_running}
  end

  defp invalid(field, message), do: {:error, {:invalid, %{field => message}}}

  defp stringify(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp to_atom_key(key) when is_atom(key), do: key
  defp to_atom_key("reply"), do: :reply
  defp to_atom_key(key), do: key

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(value) when is_atom(value), do: Atom.to_string(value)

  defp blank_to_nil(value) do
    case String.trim(to_string(value)) do
      "" -> nil
      v -> v
    end
  end
end
