defmodule AlkimWeb.ProjectsLive do
  @moduledoc """
  Landing page: the directories you work in, plus whatever is running right
  now. Adding a project is choosing a folder — the same validated browser the
  session form uses, so a project can never point outside the allowed roots.
  """

  use AlkimWeb, :live_view

  import AlkimWeb.SessionComponents, only: [work_card: 1, short_path: 1]

  alias Alkim.{Projects, Runtime, Terminals, Workflow}
  alias AlkimWeb.{WorkEntry, WorkspacePicker}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Runtime.subscribe_sessions()
      Workflow.subscribe_all()
      Terminals.subscribe_all()
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

    terminals = Enum.map(Terminals.list_active(), &WorkEntry.from_terminal/1)
    active = (live ++ workflows ++ terminals) |> WorkEntry.group() |> WorkEntry.sort()

    socket
    |> assign(active_count: length(active))
    |> stream(:active, active, reset: true)
  end

  defp error_message(changeset) do
    Enum.map_join(changeset.errors, "; ", fn {field, {message, _}} -> "#{field} #{message}" end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} nav={@nav} active={:projects}>
      <section class="a-hero" id="workspace-overview">
        <span class="a-eyebrow">Your local command center</span>
        <div class="a-page-head">
          <div>
            <h1 class="a-h1">Your agents. Your workspace.</h1>
            <p class="a-page-subtitle">
              Build, coordinate, and review. Every project, every agent, in one place.
            </p>
          </div>
          <button
            id="add-project"
            class="a-btn a-btn-primary"
            phx-click={JS.push("open", target: "#workspace-picker")}
          >
            <.icon name="hero-plus" class="size-4" /> Add project
          </button>
        </div>
      </section>

      <div class="a-stats" id="workspace-stats">
        <div class="a-stat">
          <span class="a-stat-label">Projects</span><strong class="a-stat-value">{length(
            @nav.projects
          )}</strong><span class="a-stat-icon"><.icon name="hero-folder" class="size-5" /></span>
        </div>
        <div class="a-stat">
          <span class="a-stat-label">Active work</span><strong
            class="a-stat-value"
            id="active-work-count"
          >{@active_count}</strong><span class="a-stat-icon"><.icon name="hero-bolt" class="size-5" /></span>
        </div>
        <div class="a-stat">
          <span class="a-stat-label">Harnesses ready</span><strong class="a-stat-value">{Enum.count(
            @nav.harnesses,
            &(&1.status == :available)
          )}</strong><span class="a-stat-icon"><.icon name="hero-command-line" class="size-5" /></span>
        </div>
      </div>

      <section class="a-section" id="projects">
        <div class="a-section-head">
          <h2 class="a-h2">
            <.icon name="hero-folder" class="size-4 a-faint" /> Projects
            <span class="a-tag">{length(@nav.projects)}</span>
          </h2><span class="a-hint">Pick up where you left off</span>
        </div>
        <div class="a-grid a-project-grid">
          <.link
            :for={project <- @nav.projects}
            navigate={~p"/projects/#{project.id}"}
            id={"project-#{project.id}"}
            class="a-card a-card-project"
          >
            <div class="a-card-head">
              <span class="a-project-symbol"><.icon name="hero-code-bracket" class="size-5" /></span>
              <span :if={@nav.active_counts[project.id]} class="a-badge">{@nav.active_counts[
                project.id
              ]} active</span>
              <span :if={!@nav.active_counts[project.id]} class="a-tag">Idle</span>
            </div>
            <p class="a-card-title">{project.name}</p>
            <p class="a-mono a-faint a-truncate" title={project.path}>{short_path(project.path)}</p>
            <div class="a-card-foot">
              <span>Local workspace</span><span class="flex items-center gap-2">Open project
              <.icon name="hero-arrow-up-right" class="size-3.5" /></span>
            </div>
          </.link>
          <button
            id="add-project-card"
            class="a-card a-card-project a-card-add"
            phx-click={JS.push("open", target: "#workspace-picker")}
          >
            <span class="a-project-symbol"><.icon name="hero-plus" class="size-5" /></span>
            <span>Add a project</span><span class="a-hint">Connect a folder. Start building.</span>
          </button>
        </div>
      </section>

      <section class="a-section" id="active-work">
        <div class="a-section-head">
          <h2 class="a-h2">
            <.icon name="hero-bolt" class="size-4 a-faint" /> Active work
            <span class="a-tag">{@active_count}</span>
          </h2>
          <.link navigate={~p"/sessions"} class="a-link text-xs">View all sessions →</.link>
        </div>
        <div :if={@active_count == 0} class="a-panel a-empty a-empty-rich" id="active-work-empty">
          <.icon name="hero-command-line" class="size-7 shrink-0 a-muted" />
          <div>
            <strong>Ready when you are.</strong><p>
              Open a project to start a terminal, or give an agent a task.
            </p>
          </div>
          <.link navigate={~p"/sessions/new"} class="a-btn">New session</.link>
        </div>
        <div class="a-grid" id="active-work-list" phx-update="stream">
          <.work_card :for={{id, entry} <- @streams.active} entry={entry} id={id} />
        </div>
      </section>

      <section class="a-section" id="harnesses">
        <div class="a-section-head">
          <div>
            <h2 class="a-h2">
              <.icon name="hero-cpu-chip" class="size-4 a-faint" /> Agent harnesses
            </h2><p class="a-section-caption">The CLIs on your machine, ready to work.</p>
          </div>
          <button
            id="rescan-harnesses"
            class="a-btn a-btn-ghost a-btn-sm"
            phx-click="rescan"
            phx-disable-with="Scanning…"
          ><.icon name="hero-arrow-path" class="size-3.5" /> Rescan</button>
        </div>
        <div class="a-panel a-rows">
          <div class="a-row a-row-harness a-table-head">
            <span></span><span>Harness</span><span class="a-hide-sm">Executable / version</span><span>Availability</span>
          </div>
          <div :if={@nav.harnesses == []} class="a-empty">Scanning for harnesses…</div>
          <div :for={h <- @nav.harnesses} class="a-row a-row-harness" id={"harness-#{h.id}"}>
            <span class={["a-check", check_class(h.status)]}>{check_mark(h.status)}</span>
            <span class="a-harness-name">{h.name}</span>
            <span class="a-mono a-faint a-truncate a-hide-sm" title={h.executable}>{h.executable &&
              short_path(h.executable)}{h.version && "  ·  #{h.version}"}</span>
            <span class={["a-harness-status", check_class(h.status)]}>{status_label(h.status)}</span>
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
