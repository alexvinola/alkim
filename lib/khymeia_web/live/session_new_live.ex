defmodule KhymeiaWeb.SessionNewLive do
  @moduledoc """
  Form to start a session: workspace, harness, model (only when the adapter
  accepts one), permission mode (only when the adapter declares modes) and
  prompt. Submitting goes through `Khymeia.Runtime.start_session/1`; the UI
  never launches anything itself.
  """

  use KhymeiaWeb, :live_view

  import KhymeiaWeb.WorkspacePicker, only: [workspace_field: 1]

  alias KhymeiaWeb.WorkspacePicker

  import KhymeiaWeb.SessionComponents, only: [mode_tabs: 1]

  alias Khymeia.Runtime
  alias KhymeiaWeb.HarnessOptions

  @impl true
  def mount(_params, _session, socket) do
    harnesses = Runtime.harnesses()
    available = Enum.filter(harnesses, &(&1.status == :available))
    options = HarnessOptions.build(harnesses)

    params = %{
      "workspace" => default_workspace(),
      "harness" => HarnessOptions.first_value(options),
      "model" => "",
      "custom_model" => "",
      "permission_mode" => "",
      "prompt" => ""
    }

    {:ok,
     socket
     |> assign(
       page_title: "New session · Khymeia",
       harnesses: harnesses,
       available: available,
       options: options
     )
     |> assign(errors: %{})
     |> assign_params(params)}
  end

  @impl true
  def handle_event("change", %{"session" => params}, socket) do
    params = maybe_reset_harness_fields(socket.assigns.params, params)
    {:noreply, socket |> assign(errors: %{}) |> assign_params(params)}
  end

  def handle_event("start", %{"session" => params}, socket) do
    model = if params["model"] == "__custom__", do: params["custom_model"], else: params["model"]

    case Runtime.start_session(Map.put(params, "model", model)) do
      {:ok, session} ->
        {:noreply, push_navigate(socket, to: ~p"/sessions/#{session.id}")}

      {:error, {:invalid, errors}} ->
        {:noreply, socket |> assign(errors: errors) |> assign_params(params)}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Could not start session: #{inspect(reason)}")
         |> assign_params(params)}
    end
  end

  defp assign_params(socket, params) do
    option = HarnessOptions.find(socket.assigns.options, params["harness"])
    harness = option && option.harness

    assign(socket,
      params: params,
      form: to_form(params, as: :session),
      option: option,
      harness: harness,
      models: if(option, do: HarnessOptions.models(option), else: []),
      caps: harness && harness.capabilities
    )
  end

  # Model and permission values are harness-specific.
  defp maybe_reset_harness_fields(%{"harness" => same}, %{"harness" => same} = params), do: params

  defp maybe_reset_harness_fields(_old, params),
    do: Map.merge(params, %{"model" => "", "custom_model" => "", "permission_mode" => ""})

  # The last workspace used, else the first allowed root.
  defp default_workspace do
    List.first(Runtime.recent_workspaces(1)) || List.first(Khymeia.Workspace.roots())
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
    <Layouts.app flash={@flash} active={:new}>
      <div class="k-section-head">
        <h1 class="k-h1">New session</h1>
        <.mode_tabs active={:chat} />
      </div>

      <div :if={@available == []} class="k-banner" style="margin-bottom:1.5rem">
        No supported harness is installed. Install Claude Code or Codex, then rescan from the dashboard.
      </div>

      <.form for={@form} id="new-session" class="k-form" phx-change="change" phx-submit="start">
        <.workspace_field
          name="session[workspace]"
          value={@params["workspace"]}
          error={@errors[:workspace]}
        />

        <div class="k-field-row">
          <div class="k-field">
            <label class="k-label" for="session_harness">Harness</label>
            <select id="session_harness" name="session[harness]" class="k-select">
              <option
                :for={o <- @options}
                value={o.value}
                selected={o.value == @params["harness"]}
                disabled={o.disabled}
              >
                {o.label}
              </option>
            </select>
            <span :if={@errors[:harness]} class="k-error">{@errors[:harness]}</span>
            <span :if={@option && @option.profile} class="k-hint">
              Runs the local {@harness.name} CLI; model inference goes to {Khymeia.Providers.Profile.kind_label(
                @option.profile.kind
              )}.
            </span>
          </div>

          <div :if={@caps && @caps.model_selection} class="k-field">
            <label class="k-label" for="session_model">Model</label>
            <select id="session_model" name="session[model]" class="k-select">
              <option value="">{default_model_label(@option)}</option>
              <option
                :for={m <- @models}
                value={m.id}
                selected={m.id == @params["model"]}
                title={m.description}
              >
                {model_label(m)}
              </option>
              <option
                :if={@caps.models == :unknown}
                value="__custom__"
                selected={@params["model"] == "__custom__"}
              >
                Other (type a model name)…
              </option>
            </select>
            <input
              :if={@params["model"] == "__custom__"}
              id="session_custom_model"
              name="session[custom_model]"
              value={@params["custom_model"]}
              class="k-input k-mono"
              placeholder="model name or alias accepted by the CLI"
              autocomplete="off"
            />
            <span :if={@errors[:model]} class="k-error">{@errors[:model]}</span>
            <span :if={@models != [] and @caps.models == :unknown and !@option.profile} class="k-hint">
              Reported by the installed {@harness.name} CLI.
            </span>
          </div>
        </div>

        <div :if={@caps && @caps.permission_modes != []} class="k-field">
          <label class="k-label" for="session_permission_mode">Permissions</label>
          <select id="session_permission_mode" name="session[permission_mode]" class="k-select">
            <option value="">Default / configured in harness</option>
            <option
              :for={{value, label} <- @caps.permission_modes}
              value={value}
              selected={value == @params["permission_mode"]}
            >
              {label}
            </option>
          </select>
          <span :if={@errors[:permission_mode]} class="k-error">{@errors[:permission_mode]}</span>
          <span class="k-hint">
            Non-interactive runs cannot ask for approval; this decides what the agent may do on its own.
          </span>
        </div>

        <div class="k-field">
          <label class="k-label" for="session_prompt">Prompt</label>
          <textarea
            id="session_prompt"
            name="session[prompt]"
            class="k-textarea"
            placeholder="Implement support for…"
            phx-hook="SubmitOnMetaEnter"
          >{@params["prompt"]}</textarea>
          <span :if={@errors[:prompt]} class="k-error">{@errors[:prompt]}</span>
        </div>

        <div>
          <button
            type="submit"
            class="k-btn k-btn-primary"
            disabled={@available == []}
            phx-disable-with="Starting…"
          >
            Start session
          </button>
          <span class="k-hint" style="margin-left:.75rem">⌘ + Enter</span>
        </div>
      </.form>

      <.live_component module={WorkspacePicker} id="workspace-picker" value={@params["workspace"]} />
    </Layouts.app>
    """
  end

  defp model_label(%{id: id, name: name}) when name in [nil, ""] or name == id, do: id
  defp model_label(%{id: id, name: name}), do: "#{name} (#{id})"

  defp default_model_label(%{profile: %{} = profile}) do
    if Khymeia.Providers.Profile.requires_model?(profile) and is_nil(profile.default_model),
      do: "Choose a model / deployment…",
      else: "Default / configured in provider profile"
  end

  defp default_model_label(_), do: "Default / configured in harness"
end
