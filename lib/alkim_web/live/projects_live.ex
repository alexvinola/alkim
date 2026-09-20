defmodule AlkimWeb.ProjectsLive do
  @moduledoc """
  Landing page: the directories you work in, plus whatever is running right
  now. Adding a project is choosing a folder — the same validated browser the
  session form uses, so a project can never point outside the allowed roots.
  """

  use AlkimWeb, :live_view

  import AlkimWeb.SessionComponents, only: [work_card: 1, short_path: 1]

  alias Alkim.{Projects, Runtime, Workflow}
  alias AlkimWeb.{WorkEntry, WorkspacePicker}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Runtime.subscribe_sessions()
      Workflow.subscribe_all()
    end

    {:ok, socket |> assign(page_title: "Projects · Alkim") |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # The sidebar's "+" links here with ?add=1 so any page can start the flow.
    if connected?(socket) and params["add"] == "1" do
      send_update(WorkspacePicker, id: "workspace-picker", open: true)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("rescan", _params, socket) do
    Runtime.refresh_harnesses()
    {:noreply, socket}
  end

  @impl true
  def handle_info({:workspace_selected, path}, socket) do
    case Projects.create(%{"path" => path}) do
      {:ok, project} ->
        {:noreply, push_navigate(socket, to: ~p"/projects/#{project.id}")}

      {:error, changeset} ->
        # A folder already registered is not an error: open what is there.
        case Projects.get_by_path(path) do
          nil ->
            {:noreply, put_flash(socket, :error, error_message(changeset))}

          project ->
            {:noreply, push_navigate(socket, to: ~p"/projects/#{project.id}")}
        end
    end
  end

  def handle_info(_message, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    live =
      Runtime.list_live()
      |> Enum.reject(&Alkim.Session.terminal?(&1.status))
      |> Enum.map(&WorkEntry.from_session/1)

    workflows =
      Workflow.list_recent(20)
      |> Enum.filter(&Workflow.Run.active?/1)
      |> Enum.map(&WorkEntry.from_run/1)

    assign(socket, active: WorkEntry.sort(live ++ workflows))
  end

  defp error_message(changeset) do
    Enum.map_join(changeset.errors, "; ", fn {field, {message, _}} -> "#{field} #{message}" end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} nav={@nav} active={:projects}>
      <div class="a-page-head">
        <h1 class="a-h1">Projects</h1>
        <button
          class="a-btn a-btn-primary"
          phx-click={JS.push("open", target: "#workspace-picker")}
        >
          <.icon name="hero-plus" class="size-4" /> Add project
        </button>
      </div>

      <section class="a-section">
        <div :if={@nav.projects == []} class="a-panel a-empty">
          Add the folder you work in. Alkim only ever runs harnesses inside it.
        </div>

        <div class="a-grid">
          <.link
            :for={project <- @nav.projects}
            navigate={~p"/projects/#{project.id}"}
            id={"project-#{project.id}"}
            class="a-card a-card-project"
          >
            <div class="a-card-head">
              <.icon name="hero-folder" class="size-4 a-faint" />
              <span :if={@nav.active_counts[project.id]} class="a-badge">
                {@nav.active_counts[project.id]} active
              </span>
            </div>
            <p class="a-card-title">{project.name}</p>
            <p class="a-mono a-faint a-truncate">{short_path(project.path)}</p>
          </.link>
        </div>
      </section>

      <section class="a-section" id="active-work">
        <div class="a-section-head">
          <h2 class="a-h2">Running now</h2>
          <.link navigate={~p"/sessions"} class="a-link">All sessions</.link>
        </div>

        <div :if={@active == []} class="a-panel a-empty">Nothing is running.</div>
        <div class="a-grid">
          <.work_card :for={entry <- @active} entry={entry} />
        </div>
      </section>

      <section class="a-section" id="harnesses">
        <div class="a-section-head">
          <h2 class="a-h2">Installed harnesses</h2>
          <button class="a-btn a-btn-ghost" phx-click="rescan" phx-disable-with="Scanning…">
            Rescan
          </button>
        </div>
        <div class="a-panel a-rows">
          <div :if={@nav.harnesses == []} class="a-empty">Scanning for harnesses…</div>
          <div :for={h <- @nav.harnesses} class="a-row a-row-harness" id={"harness-#{h.id}"}>
            <span class={["a-check", check_class(h.status)]}>{check_mark(h.status)}</span>
            <span>{h.name}</span>
            <span class="a-mono a-faint a-truncate a-hide-sm">
              {h.executable && short_path(h.executable)}{h.version && "  ·  #{h.version}"}
            </span>
            <span class="a-muted">{status_label(h.status)}</span>
          </div>
        </div>
      </section>

      <.live_component module={WorkspacePicker} id="workspace-picker" value={nil} />
    </Layouts.app>
    """
  end

  defp check_mark(:available), do: "✓"
  defp check_mark(:no_adapter), do: "◐"
  defp check_mark(:not_installed), do: "○"

  defp check_class(:available), do: "a-check-yes"
  defp check_class(:no_adapter), do: "a-check-partial"
  defp check_class(:not_installed), do: "a-check-no"

  defp status_label(:available), do: "ready"
  defp status_label(:no_adapter), do: "installed · no adapter yet"
  defp status_label(:not_installed), do: "not installed"
end
