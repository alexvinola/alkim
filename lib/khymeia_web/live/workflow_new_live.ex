defmodule KhymeiaWeb.WorkflowNewLive do
  @moduledoc """
  Workflow mode of "New session": pick a preset, describe the task and map
  each role to an installed harness/model. Only detected harnesses are
  offered; defaults come from the capability tiers.
  """

  use KhymeiaWeb, :live_view

  import KhymeiaWeb.WorkspacePicker, only: [workspace_field: 1]

  alias KhymeiaWeb.WorkspacePicker

  import KhymeiaWeb.SessionComponents, only: [mode_tabs: 1]

  alias Khymeia.{Runtime, Workflow}
  alias Khymeia.Workflow.{Definition, Presets, Role}

  @impl true
  def mount(params, _session, socket) do
    harnesses = Enum.filter(socket.assigns.nav.harnesses, &(&1.status == :available))
    options = Enum.reject(KhymeiaWeb.HarnessOptions.build(harnesses), & &1.disabled)
    preset = hd(Enum.filter(Presets.all(), &(&1.name == "coding-with-audit")) ++ Presets.all())

    params = %{
      "workspace" => default_workspace(params["project"]),
      "workflow" => preset.name,
      "task" => "",
      "constraints" => "",
      "max_iterations" => to_string(preset.max_iterations),
      "roles" => default_roles(preset)
    }

    {:ok,
     socket
     |> assign(
       page_title: "New workflow · Khymeia",
       harnesses: harnesses,
       options: options,
       presets: Presets.all(),
       errors: %{}
     )
     |> assign_params(params)}
  end

  @impl true
  def handle_event("change", %{"workflow" => params}, socket) do
    params = reconcile(socket.assigns.params, params)
    {:noreply, socket |> assign(errors: %{}) |> assign_params(params)}
  end

  def handle_event("run", %{"workflow" => params}, socket) do
    params = reconcile(socket.assigns.params, params)

    roles =
      Map.new(params["roles"], fn {role, spec} ->
        model = if spec["model"] == "__custom__", do: spec["custom_model"], else: spec["model"]

        {role,
         %{
           "harness" => spec["harness"],
           "model" => model,
           "permission_mode" => spec["permission_mode"]
         }}
      end)

    case Workflow.start(Map.put(params, "roles", roles)) do
      {:ok, run} ->
        {:noreply, push_navigate(socket, to: ~p"/workflows/#{run.id}")}

      {:error, {:invalid, errors}} ->
        {:noreply, socket |> assign(errors: errors) |> assign_params(params)}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Could not start: #{inspect(reason)}")
         |> assign_params(params)}
    end
  end

  # A new preset brings its own roles; a new harness resets that role's model.
  defp reconcile(old, new) do
    if old["workflow"] != new["workflow"] do
      {:ok, preset} = Presets.fetch(new["workflow"])

      Map.merge(new, %{
        "roles" => default_roles(preset),
        "max_iterations" => to_string(preset.max_iterations)
      })
    else
      roles =
        Map.new(new["roles"] || %{}, fn {role, spec} ->
          if get_in(old, ["roles", role, "harness"]) == spec["harness"],
            do: {role, spec},
            else:
              {role,
               Map.merge(spec, %{"model" => "", "custom_model" => "", "permission_mode" => ""})}
        end)

      Map.put(new, "roles", roles)
    end
  end

  defp assign_params(socket, params) do
    {:ok, preset} = Presets.fetch(params["workflow"])
    assign(socket, params: params, preset: preset, form: to_form(params, as: :workflow))
  end

  defp default_roles(preset) do
    preset
    |> Workflow.default_roles()
    |> Map.new(fn {role, %{choice: choice, model: model}} ->
      {Atom.to_string(role),
       %{
         "harness" => choice || "",
         "model" => model || "",
         "custom_model" => "",
         "permission_mode" => ""
       }}
    end)
  end

  # The last workspace used, else the first allowed root.
  # The project this form was opened from, else the last workspace used.
  defp default_workspace(project_id) do
    case Khymeia.Projects.get(project_id) do
      %{path: path} -> path
      nil -> List.first(Runtime.recent_workspaces(1)) || List.first(Khymeia.Workspace.roots())
    end
  end

  @impl true
  def handle_info({:workspace_selected, path}, socket) do
    params = Map.put(socket.assigns.params, "workspace", path)

    {:noreply,
     socket
     |> assign(errors: Map.delete(socket.assigns.errors, :workspace))
     |> assign_params(params)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} nav={@nav} active={:new}>
      <div class="k-section-head">
        <h1 class="k-h1">New workflow</h1>
        <.mode_tabs active={:workflow} />
      </div>

      <div :if={@harnesses == []} class="k-banner" style="margin-bottom:1.5rem">
        No supported harness is installed.
      </div>

      <.form for={@form} id="new-workflow" class="k-form" phx-change="change" phx-submit="run">
        <.workspace_field
          name="workflow[workspace]"
          value={@params["workspace"]}
          error={@errors[:workspace]}
        />

        <div class="k-field">
          <label class="k-label" for="workflow_workflow">Workflow</label>
          <select id="workflow_workflow" name="workflow[workflow]" class="k-select">
            <option :for={p <- @presets} value={p.name} selected={p.name == @params["workflow"]}>
              {p.title} — {p.description}
            </option>
          </select>
        </div>

        <div class="k-field">
          <label class="k-label" for="workflow_task">Task</label>
          <textarea
            id="workflow_task"
            name="workflow[task]"
            class="k-textarea"
            placeholder="Implement …"
            phx-hook="SubmitOnMetaEnter"
          >{@params["task"]}</textarea>
          <span :if={@errors[:task]} class="k-error">{@errors[:task]}</span>
        </div>

        <div class="k-field">
          <label class="k-label" for="workflow_constraints">
            Architectural constraints <span class="k-muted" style="font-weight:400">(optional)</span>
          </label>
          <textarea
            id="workflow_constraints"
            name="workflow[constraints]"
            class="k-textarea"
            style="min-height:4.5rem"
            placeholder="e.g. no new dependencies; keep the public API unchanged"
          >{@params["constraints"]}</textarea>
        </div>

        <div class="k-roles">
          <.role_row
            :for={role <- Definition.roles_used(@preset)}
            role={role}
            tier={get_in(@preset.roles, [role, :tier])}
            spec={@params["roles"][Atom.to_string(role)] || %{}}
            options={@options}
            error={@errors[:"role_#{role}"]}
          />
        </div>

        <div :if={@preset.repeat} class="k-field" style="max-width:12rem">
          <label class="k-label" for="workflow_max_iterations">Max iterations</label>
          <input
            id="workflow_max_iterations"
            name="workflow[max_iterations]"
            type="number"
            min="1"
            max="10"
            value={@params["max_iterations"]}
            class="k-input"
          />
          <span :if={@errors[:max_iterations]} class="k-error">{@errors[:max_iterations]}</span>
        </div>
        <input
          :if={!@preset.repeat}
          type="hidden"
          name="workflow[max_iterations]"
          value={@params["max_iterations"]}
        />

        <div>
          <button
            type="submit"
            class="k-btn k-btn-primary"
            disabled={@harnesses == []}
            phx-disable-with="Starting…"
          >
            Run workflow
          </button>
        </div>
      </.form>

      <.live_component module={WorkspacePicker} id="workspace-picker" value={@params["workspace"]} />
    </Layouts.app>
    """
  end

  attr :role, :atom, required: true
  attr :tier, :atom, default: nil
  attr :spec, :map, required: true
  attr :options, :list, required: true
  attr :error, :string, default: nil

  defp role_row(assigns) do
    option = KhymeiaWeb.HarnessOptions.find(assigns.options, assigns.spec["harness"])
    harness = option && option.harness
    role = harness && Role.assign(assigns.role, harness.id, nil, nil, harness.capabilities)

    assigns =
      assign(assigns,
        option: option,
        harness: harness,
        models: if(option, do: KhymeiaWeb.HarnessOptions.models(option), else: []),
        assignment: role,
        name: "workflow[roles][#{assigns.role}]"
      )

    ~H"""
    <div class="k-role" id={"role-#{@role}"}>
      <div class="k-role-head">
        <span class="k-label">{Role.title(@role)}</span>
        <span :if={@tier} class="k-tag">tier: {@tier}</span>
      </div>
      <div class="k-field-row">
        <select name={"#{@name}[harness]"} class="k-select" id={"role_#{@role}_harness"}>
          <option :if={@role == :advisor} value="none" selected={@spec["harness"] in ["none", ""]}>
            None — no consultations
          </option>
          <option :for={o <- @options} value={o.value} selected={o.value == @spec["harness"]}>
            {o.label}
          </option>
        </select>

        <div
          :if={@harness && @harness.capabilities.model_selection}
          class="k-field"
          style="gap:.35rem"
        >
          <select name={"#{@name}[model]"} class="k-select" id={"role_#{@role}_model"}>
            <option value="">
              {if @option.profile,
                do: "Default / configured in provider profile",
                else: "Default / configured in harness"}
            </option>
            <option
              :for={m <- @models}
              value={m.id}
              selected={m.id == @spec["model"]}
              title={m.description}
            >
              {if m.name in [nil, "", m.id], do: m.id, else: "#{m.name} (#{m.id})"}
            </option>
            <option
              :if={@harness.capabilities.models == :unknown}
              value="__custom__"
              selected={@spec["model"] == "__custom__" or custom?(@spec["model"], @models)}
            >
              Other (type a model name)…
            </option>
          </select>
          <input
            :if={@spec["model"] == "__custom__" or custom?(@spec["model"], @models)}
            name={"#{@name}[custom_model]"}
            value={@spec["custom_model"] || @spec["model"]}
            class="k-input k-mono"
            placeholder="model name accepted by the CLI"
          />
        </div>
      </div>

      <div :if={
        @assignment && @assignment.permissions.write && @harness.capabilities.permission_modes != []
      }>
        <select
          name={"#{@name}[permission_mode]"}
          class="k-select"
          id={"role_#{@role}_permission_mode"}
        >
          <option
            :for={{value, label} <- @harness.capabilities.permission_modes}
            value={value}
            selected={value == (blank(@spec["permission_mode"]) || @harness.capabilities.write_mode)}
          >
            {label}
          </option>
        </select>
      </div>
      <span
        :if={@assignment && !@assignment.permissions.write}
        class={["k-hint", @assignment.enforcement == :none && "k-warn"]}
      >
        {Role.enforcement_note(@assignment)}
      </span>
      <span :if={@error} class="k-error">{@error}</span>
    </div>
    """
  end

  defp custom?(model, models),
    do: model not in [nil, "", "__custom__"] and not Enum.any?(models, &(&1.id == model))

  defp blank(""), do: nil
  defp blank(value), do: value
end
