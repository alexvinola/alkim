defmodule KhymeiaWeb.ProjectLive do
  @moduledoc """
  A project's working surface: start something, watch what is running, and
  see what git makes of the folder.

  The composer starts a session through `Khymeia.Runtime` like any other
  entry point — the view never spawns anything itself. Workflows keep their
  own form, because mapping roles to harnesses is a decision Khymeia must
  not take for the user.
  """

  use KhymeiaWeb, :live_view

  import KhymeiaWeb.SessionComponents,
    only: [work_card: 1, work_row: 1, short_path: 1, datetime: 1]

  alias Khymeia.{Git, Projects, Runtime, Workflow}
  alias KhymeiaWeb.{HarnessOptions, WorkEntry}

  @tabs ~w(overview git settings)

  # A repository without a .gitignore can report thousands of untracked
  # files; the page shows a workable slice and says how many are left.
  @change_limit 100

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Runtime.subscribe_sessions()
      Workflow.subscribe_all()
    end

    {:ok, assign(socket, prompt: "", harness: nil, errors: %{})}
  end

  @impl true
  def handle_params(%{"id" => id} = params, _uri, socket) do
    case Projects.get(id) do
      nil ->
        {:noreply, socket |> put_flash(:error, "Project not found") |> push_navigate(to: ~p"/")}

      project ->
        tab = if params["tab"] in @tabs, do: params["tab"], else: "overview"

        {:noreply,
         socket
         |> assign(
           project: project,
           tab: tab,
           change_limit: @change_limit,
           page_title: "#{project.name} · Khymeia"
         )
         |> assign_options()
         |> load()
         |> maybe_load_git()}
    end
  end

  @impl true
  def handle_event("compose", %{"start" => params}, socket) do
    {:noreply, assign(socket, prompt: params["prompt"], harness: params["harness"])}
  end

  def handle_event("start", %{"start" => params}, socket) do
    attrs = Map.put(params, "workspace", socket.assigns.project.path)

    case Runtime.start_session(attrs) do
      {:ok, session} ->
        {:noreply, push_navigate(socket, to: ~p"/sessions/#{session.id}")}

      {:error, {:invalid, errors}} ->
        {:noreply, assign(socket, errors: errors, prompt: params["prompt"])}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not start session: #{inspect(reason)}")}
    end
  end

  def handle_event("rename", %{"project" => %{"name" => name}}, socket) do
    case Projects.rename(socket.assigns.project, name) do
      {:ok, project} ->
        {:noreply, socket |> assign(project: project) |> put_flash(:info, "Project renamed")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "That name is not valid")}
    end
  end

  def handle_event("delete", _params, socket) do
    {:ok, _} = Projects.delete(socket.assigns.project)

    {:noreply,
     socket
     |> put_flash(:info, "Project removed. Its sessions are kept in history.")
     |> push_navigate(to: ~p"/")}
  end

  def handle_event("refresh_git", _params, socket), do: {:noreply, load_git(socket)}

  @impl true
  def handle_info(_message, socket), do: {:noreply, load(socket)}

  ## Loading

  defp assign_options(socket) do
    options = HarnessOptions.build(socket.assigns.nav.harnesses)

    assign(socket,
      options: options,
      harness: socket.assigns.harness || HarnessOptions.first_value(options)
    )
  end

  defp load(%{assigns: %{project: project}} = socket) do
    live =
      Runtime.list_live()
      |> Enum.filter(&(&1[:project_id] == project.id))
      |> Enum.reject(&Khymeia.Session.terminal?(&1.status))
      |> Enum.map(&WorkEntry.from_session/1)

    live_ids = MapSet.new(live, & &1.id)

    history =
      (Runtime.list_recent_for_project(project.id, 20) |> Enum.map(&WorkEntry.from_session/1)) ++
        (Workflow.list_recent_for_project(project.id, 20) |> Enum.map(&WorkEntry.from_run/1))

    history = Enum.reject(history, &MapSet.member?(live_ids, &1.id))
    {active, recent} = Enum.split_with(WorkEntry.sort(live ++ history), & &1.active?)

    assign(socket, active: active, recent: recent, sidebar: Enum.take(active ++ recent, 12))
  end

  defp maybe_load_git(%{assigns: %{tab: "git"}} = socket), do: load_git(socket)
  defp maybe_load_git(socket), do: assign_new(socket, :git, fn -> nil end)

  defp load_git(socket) do
    path = socket.assigns.project.path
    assign_async(socket, :git, fn -> {:ok, %{git: Git.status(path)}} end)
  end

  ## Rendering

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} nav={@nav} active={:projects} project={@project} sessions={@sidebar}>
      <div class="k-page-head">
        <div class="k-page-title">
          <.icon name="hero-folder" class="size-5 k-faint" />
          <h1 class="k-h1">{@project.name}</h1>
          <span class="k-mono k-faint k-truncate">{short_path(@project.path)}</span>
        </div>
        <.link navigate={~p"/workflows/new?project=#{@project.id}"} class="k-btn">
          New workflow
        </.link>
      </div>

      <nav class="k-tabs k-tabs-page" aria-label="Project">
        <.link
          :for={{tab, label} <- [{"overview", "Overview"}, {"git", "Git"}, {"settings", "Settings"}]}
          patch={~p"/projects/#{@project.id}/#{tab}"}
          aria-current={@tab == tab && "page"}
        >
          {label}
        </.link>
      </nav>

      <.overview :if={@tab == "overview"} {assigns} />
      <.git_tab :if={@tab == "git"} {assigns} />
      <.settings :if={@tab == "settings"} {assigns} />
    </Layouts.app>
    """
  end

  defp overview(assigns) do
    ~H"""
    <section class="k-section">
      <form
        id="composer"
        class="k-composer-box"
        phx-change="compose"
        phx-submit="start"
        autocomplete="off"
      >
        <textarea
          id="composer-prompt"
          name="start[prompt]"
          class="k-textarea k-composer-input"
          placeholder="Describe what you want done in this project…"
          phx-hook="SubmitOnMetaEnter"
        >{@prompt}</textarea>
        <span :if={@errors[:prompt]} class="k-error">{@errors[:prompt]}</span>

        <div class="k-composer-bar">
          <select id="composer-harness" name="start[harness]" class="k-select k-select-inline">
            <option
              :for={o <- @options}
              value={o.value}
              selected={o.value == @harness}
              disabled={o.disabled}
            >
              {o.label}
            </option>
          </select>
          <.link navigate={~p"/sessions/new?project=#{@project.id}"} class="k-link">
            More options
          </.link>
          <span class="k-spacer"></span>
          <span class="k-hint k-hide-sm">⌘ + Enter</span>
          <button type="submit" class="k-btn k-btn-primary" phx-disable-with="Starting…">
            Start session
          </button>
        </div>
        <span :if={@errors[:harness]} class="k-error">{@errors[:harness]}</span>
      </form>
    </section>

    <section class="k-section" id="project-active">
      <div class="k-section-head">
        <h2 class="k-h2">Active <span class="k-badge">{length(@active)}</span></h2>
      </div>
      <div :if={@active == []} class="k-panel k-empty">Nothing running in this project.</div>
      <div class="k-grid">
        <.work_card :for={entry <- @active} entry={entry} />
      </div>
    </section>

    <section class="k-section" id="project-recent">
      <div class="k-section-head">
        <h2 class="k-h2">Recent</h2>
      </div>
      <div class="k-panel k-rows">
        <div :if={@recent == []} class="k-empty">Finished work appears here.</div>
        <.work_row :for={entry <- @recent} entry={entry} id={"recent-#{entry.id}"} />
      </div>
    </section>
    """
  end

  defp git_tab(assigns) do
    ~H"""
    <section class="k-section" id="project-git">
      <div class="k-section-head">
        <h2 class="k-h2">Repository</h2>
        <button class="k-btn k-btn-ghost" phx-click="refresh_git" phx-disable-with="Reading…">
          Refresh
        </button>
      </div>

      <.async_result :let={git} assign={@git}>
        <:loading>
          <div class="k-panel k-empty">Reading the repository…</div>
        </:loading>
        <:failed :let={_reason}>
          <div class="k-panel k-empty">Could not read the repository.</div>
        </:failed>

        <div :if={git == :unavailable} class="k-panel k-empty">
          This folder is not a git repository, so Khymeia cannot tell what changed.
        </div>

        <div :if={git != :unavailable} class="k-panel">
          <dl class="k-meta">
            <div>
              <dt>Branch</dt>
              <dd class="k-mono">{git.branch || "—"}</dd>
            </div>
            <div>
              <dt>Upstream</dt>
              <dd class="k-mono">{git.upstream || "none"}</dd>
            </div>
            <div :if={git.ahead || git.behind}>
              <dt>Distance</dt>
              <dd class="k-mono">↑{git.ahead || 0} ↓{git.behind || 0}</dd>
            </div>
            <div>
              <dt>Uncommitted</dt>
              <dd>{length(git.changes)} file(s)</dd>
            </div>
          </dl>
        </div>

        <div :if={git != :unavailable and git.changes != []} class="k-panel k-rows k-mt">
          <div :for={change <- Enum.take(git.changes, @change_limit)} class="k-row k-row-change">
            <span class={["k-mono", "k-change-#{String.first(change.code)}"]}>{change.code}</span>
            <span class="k-mono k-truncate">{change.path}</span>
          </div>
          <div :if={length(git.changes) > @change_limit} class="k-empty">
            and {length(git.changes) - @change_limit} more.
          </div>
        </div>

        <div :if={git != :unavailable and git.commits != []} class="k-panel k-rows k-mt">
          <div :for={commit <- git.commits} class="k-row k-row-commit">
            <span class="k-mono k-faint">{commit.hash}</span>
            <span class="k-truncate">{commit.subject}</span>
            <span class="k-muted k-truncate k-hide-sm">{commit.author}</span>
            <span class="k-faint k-hide-sm" style="text-align:right">{commit.at}</span>
          </div>
        </div>
      </.async_result>
    </section>
    """
  end

  defp settings(assigns) do
    ~H"""
    <section class="k-section" id="project-settings">
      <form class="k-form" phx-submit="rename" autocomplete="off">
        <div class="k-field">
          <label class="k-label" for="project_name">Name</label>
          <input id="project_name" name="project[name]" value={@project.name} class="k-input" />
          <span class="k-hint">Only a label. The folder on disk is never renamed.</span>
        </div>
        <div>
          <button type="submit" class="k-btn">Save</button>
        </div>
      </form>

      <dl class="k-meta k-panel k-mt">
        <div>
          <dt>Folder</dt>
          <dd class="k-mono">{@project.path}</dd>
        </div>
        <div>
          <dt>Added</dt>
          <dd>{datetime(@project.inserted_at)}</dd>
        </div>
        <div>
          <dt>Last opened</dt>
          <dd>{datetime(@project.last_opened_at)}</dd>
        </div>
      </dl>

      <div class="k-section-head k-mt">
        <div>
          <h2 class="k-h2">Remove project</h2>
          <p class="k-hint">
            Removes it from this list only. Nothing on disk is touched and its
            sessions stay in history.
          </p>
        </div>
        <button
          class="k-btn k-btn-danger"
          phx-click="delete"
          data-confirm={"Remove “#{@project.name}” from Khymeia?"}
        >
          Remove
        </button>
      </div>
    </section>
    """
  end
end
