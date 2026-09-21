defmodule AlkimWeb.ProjectLive do
  @moduledoc """
  A project's working surface: start something, watch what is running, and
  see what git makes of the folder.

  The composer starts a session through `Alkim.Runtime` like any other
  entry point — the view never spawns anything itself. Workflows keep their
  own form, because mapping roles to harnesses is a decision Alkim must
  not take for the user.
  """

  use AlkimWeb, :live_view

  on_mount AlkimWeb.TerminalPane

  import AlkimWeb.SessionComponents,
    only: [work_card: 1, work_row: 1, short_path: 1, datetime: 1]

  alias Alkim.{Git, Projects, Runtime, Terminals, Workflow, Worktrees}
  alias AlkimWeb.{HarnessOptions, WorkEntry}

  @tabs ~w(overview terminal git settings)

  # A repository without a .gitignore can report thousands of untracked
  # files; the page shows a workable slice and says how many are left.
  @change_limit 100

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Runtime.subscribe_sessions()
      Workflow.subscribe_all()
      Worktrees.subscribe()
    end

    {:ok,
     assign(socket,
       terminal: nil,
       terminals: [],
       worktrees: [],
       worktree_name: "",
       worktree_branch: "new",
       branches: [],
       terminal_harness: nil,
       terminal_options: []
     )}
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
           page_title: "#{project.name} · Alkim"
         )
         |> assign_options()
         |> load()
         |> load_worktrees()
         |> maybe_load_git()
         |> maybe_load_terminals(params)}
    end
  end

  @impl true
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

  ## Worktrees

  def handle_event("name_worktree", %{"worktree" => params}, socket) do
    {:noreply,
     assign(socket,
       worktree_name: params["name"] || socket.assigns.worktree_name,
       worktree_branch: params["branch"] || socket.assigns.worktree_branch
     )}
  end

  def handle_event("create_worktree", %{"worktree" => params}, socket) do
    branch =
      if params["branch"] in [nil, "", "new"], do: :new, else: {:existing, params["branch"]}

    case Worktrees.create(socket.assigns.project, params["name"], branch: branch) do
      {:ok, _worktree} ->
        {:noreply,
         socket |> assign(worktree_name: "", worktree_branch: "new") |> load_worktrees()}

      {:error, {:invalid, errors}} ->
        {:noreply, put_flash(socket, :error, describe(errors))}
    end
  end

  def handle_event("keep_worktree", %{"id" => id}, socket) do
    case Worktrees.keep(id) do
      {:ok, worktree} ->
        {:noreply,
         socket
         |> load_worktrees()
         |> put_flash(:info, "Directory removed. Branch #{worktree.branch} is yours to merge.")}

      {:error, {:invalid, errors}} ->
        {:noreply, put_flash(socket, :error, describe(errors))}
    end
  end

  def handle_event("discard_worktree", %{"id" => id}, socket) do
    case Worktrees.discard(id) do
      {:ok, _worktree} ->
        {:noreply, socket |> load_worktrees() |> put_flash(:info, "Worktree and branch removed.")}

      {:error, {:invalid, errors}} ->
        {:noreply, put_flash(socket, :error, describe(errors))}
    end
  end

  def handle_event("open_worktree_terminal", %{"id" => id}, socket) do
    attrs = %{"harness" => socket.assigns.terminal_harness, "worktree" => id}

    case Terminals.start(attrs) do
      {:ok, terminal} ->
        {:noreply,
         socket
         |> load()
         |> load_terminals()
         |> attach(terminal)
         |> push_patch(to: ~p"/projects/#{socket.assigns.project.id}/terminal?t=#{terminal.id}")}

      {:error, {:invalid, errors}} ->
        {:noreply, put_flash(socket, :error, "Could not open a terminal: #{describe(errors)}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not open a terminal: #{inspect(reason)}")}
    end
  end

  ## Terminal

  def handle_event("open_terminal", %{"terminal" => %{"harness" => harness}}, socket) do
    attrs = %{"harness" => harness, "workspace" => socket.assigns.project.path}

    case Terminals.start(attrs) do
      {:ok, terminal} ->
        {:noreply, socket |> load() |> load_terminals() |> attach(terminal)}

      {:error, {:invalid, errors}} ->
        {:noreply, put_flash(socket, :error, "Could not open a terminal: #{describe(errors)}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not open a terminal: #{inspect(reason)}")}
    end
  end

  def handle_event("select_terminal", %{"id" => id}, socket) do
    {:noreply, open_or_attach(socket, id)}
  end

  def handle_event("delete_terminal", %{"id" => id}, socket) do
    case Terminals.delete(id) do
      :ok ->
        socket =
          if socket.assigns.terminal && socket.assigns.terminal.id == id do
            Terminals.unsubscribe(id)
            assign(socket, terminal: nil)
          else
            socket
          end

        {:noreply,
         socket
         |> load()
         |> load_terminals()
         |> put_flash(:info, "Terminal deleted, with everything it printed.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not delete that terminal")}
    end
  end

  def handle_event("stop_terminal", _params, socket) do
    if socket.assigns.terminal, do: Terminals.stop(socket.assigns.terminal.id)
    {:noreply, socket}
  end

  def handle_event("pick_terminal_harness", %{"terminal" => %{"harness" => harness}}, socket),
    do:
      {:noreply,
       assign(socket,
         terminal_harness: harness,
         terminal_form: to_form(%{"harness" => harness}, as: :terminal)
       )}

  @impl true
  def handle_info({:terminal_status, _terminal}, socket),
    do: {:noreply, socket |> load() |> load_terminals()}

  def handle_info(:worktrees_changed, socket), do: {:noreply, load_worktrees(socket)}

  def handle_info(_message, socket), do: {:noreply, load(socket)}

  ## Loading

  defp assign_options(socket) do
    options = HarnessOptions.interactive(HarnessOptions.build(socket.assigns.nav.harnesses))

    assign(socket,
      terminal_options: options,
      terminal_form:
        to_form(
          %{"harness" => socket.assigns.terminal_harness || HarnessOptions.first_value(options)},
          as: :terminal
        ),
      terminal_harness: socket.assigns.terminal_harness || HarnessOptions.first_value(options)
    )
  end

  defp load(%{assigns: %{project: project}} = socket) do
    live =
      Runtime.list_live()
      |> Enum.filter(&(&1[:project_id] == project.id))
      |> Enum.reject(&Alkim.Session.terminal?(&1.status))
      |> Enum.map(&WorkEntry.from_session/1)

    live_ids = MapSet.new(live, & &1.id)

    terminals =
      project.id |> Terminals.list_for_project(20) |> Enum.map(&WorkEntry.from_terminal/1)

    history =
      (Runtime.list_recent_for_project(project.id, 20) |> Enum.map(&WorkEntry.from_session/1)) ++
        (Workflow.list_recent_for_project(project.id, 20) |> Enum.map(&WorkEntry.from_run/1)) ++
        terminals

    history = Enum.reject(history, &MapSet.member?(live_ids, &1.id))
    grouped = (live ++ history) |> WorkEntry.group() |> WorkEntry.sort()
    {active, recent} = Enum.split_with(grouped, & &1.active?)

    assign(socket, active: active, recent: recent, sidebar: Enum.take(active ++ recent, 12))
  end

  # On the Terminal tab, open the one asked for by id, else whichever is
  # still running: arriving at the tab should show something useful.
  defp maybe_load_terminals(%{assigns: %{tab: "terminal"}} = socket, params) do
    socket = load_terminals(socket)

    wanted =
      (params["t"] && Enum.find(socket.assigns.terminals, &(&1.id == params["t"]))) ||
        socket.assigns.terminal ||
        Enum.find(socket.assigns.terminals, &Terminals.alive?(&1.id))

    case wanted do
      nil -> socket
      terminal -> open_or_attach(socket, terminal.id)
    end
  end

  defp maybe_load_terminals(socket, _params), do: load_terminals(socket)

  # Opening a terminal that is not running puts it back on its feet, asking
  # the harness to continue where it left off. There is no separate resume
  # step: you open it and type.
  #
  # Never on the disconnected render: `handle_params` runs twice on a page
  # load, and starting an OS process is not something to do twice.
  defp open_or_attach(socket, id) do
    if Terminals.alive?(id) or not connected?(socket) do
      case Terminals.get(id) do
        nil -> socket
        terminal -> attach(socket, terminal)
      end
    else
      case Terminals.reopen(id) do
        {:ok, terminal} ->
          socket |> load() |> load_terminals() |> attach(terminal)

        {:error, {:invalid, errors}} ->
          put_flash(socket, :error, "Could not open that terminal: #{describe(errors)}")

        {:error, _reason} ->
          put_flash(socket, :error, "Could not open that terminal")
      end
    end
  end

  # Each worktree is shown with what the agent actually did in it, read from
  # git rather than from anything Alkim recorded.
  defp load_worktrees(%{assigns: %{project: project}} = socket) do
    worktrees =
      project.id
      |> Worktrees.list_for_project(12)
      |> Enum.map(&%{record: &1, work: Worktrees.work(&1)})

    assign(socket, worktrees: worktrees, branches: Worktrees.branches(project))
  end

  defp load_terminals(%{assigns: %{project: project}} = socket),
    do: assign(socket, terminals: Terminals.list_for_project(project.id, 8))

  defdelegate attach(socket, terminal), to: AlkimWeb.TerminalPane

  defp describe(errors),
    do: Enum.map_join(errors, "; ", fn {_field, message} -> message end)

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
      <div class="a-page-head">
        <div class="a-page-title">
          <span class="a-project-symbol"><.icon name="hero-code-bracket" class="size-5" /></span>
          <div>
            <h1 class="a-h1">{@project.name}</h1>
            <p class="a-mono a-faint a-truncate" title={@project.path}>{short_path(@project.path)}</p>
          </div>
        </div>
        <.link navigate={~p"/workflows/new?project=#{@project.id}"} class="a-btn">
          New workflow
        </.link>
      </div>

      <div class="a-tabs-row">
        <nav class="a-tabs a-tabs-page" aria-label="Project">
          <.link
            :for={
              {tab, label} <- [
                {"overview", "Overview"},
                {"terminal", "Terminal"},
                {"git", "Git"},
                {"settings", "Settings"}
              ]
            }
            patch={~p"/projects/#{@project.id}/#{tab}"}
            aria-current={@tab == tab && "page"}
          >
            <.icon name={tab_icon(tab)} class="size-3.5" /> {label}
          </.link>
        </nav>

        <.terminal_controls :if={@tab == "terminal"} terminal={@terminal} />
      </div>

      <.overview :if={@tab == "overview"} {assigns} />
      <.terminal_tab :if={@tab == "terminal"} {assigns} />
      <.git_tab :if={@tab == "git"} {assigns} />
      <.settings :if={@tab == "settings"} {assigns} />
    </Layouts.app>
    """
  end

  defp tab_icon("overview"), do: "hero-squares-2x2"
  defp tab_icon("terminal"), do: "hero-command-line"
  defp tab_icon("git"), do: "hero-code-bracket"
  defp tab_icon("settings"), do: "hero-cog-6-tooth"

  defp overview(assigns) do
    ~H"""
    <section class="a-section">
      <div class="a-launcher">
        <div class="a-launcher-copy">
          <strong>Make your next move.</strong><span class="a-hint">Open an agent's native CLI, right inside your project.</span>
        </div>
        <.form
          for={@terminal_form}
          id="open-terminal"
          phx-submit="open_terminal"
          phx-change="pick_terminal_harness"
          class="a-launcher-form"
        >
          <.input
            type="select"
            field={@terminal_form[:harness]}
            options={Enum.map(@terminal_options, &{&1.label, &1.value})}
            class="a-select a-select-inline"
            id="overview_harness"
            aria-label="Terminal harness"
          />
          <button
            type="submit"
            class="a-btn a-btn-primary"
            disabled={@terminal_options == []}
            phx-disable-with="Opening…"
            id="overview-open-terminal"
          >
            Open terminal
          </button>
        </.form>
        <div class="a-launcher-links">
          <span class="a-hint">Prefer to delegate a task?</span>
          <.link navigate={~p"/sessions/new?project=#{@project.id}"} class="a-btn a-btn-ghost"><.icon
            name="hero-chat-bubble-left-right"
            class="size-4"
          /> New session</.link>
          <.link navigate={~p"/workflows/new?project=#{@project.id}"} class="a-btn a-btn-ghost"><.icon
            name="hero-square-3-stack-3d"
            class="size-4"
          /> New workflow</.link>
        </div>
      </div>

      <p :if={@terminal_options == []} class="a-hint" style="margin-top:.6rem">
        No installed harness has a verified interactive mode yet.
      </p>
    </section>

    <section class="a-section" id="project-active">
      <div class="a-section-head">
        <h2 class="a-h2">
          <.icon name="hero-bolt" class="size-4 a-faint" /> Active
          <span class="a-badge">{length(@active)}</span>
        </h2>
      </div>
      <div :if={@active == []} class="a-panel a-empty">
        Nothing running in this project. Open a terminal to work with an agent directly.
      </div>
      <div class="a-grid">
        <.work_card :for={entry <- @active} entry={entry} />
      </div>
    </section>

    <section class="a-section" id="project-worktrees">
      <div class="a-section-head">
        <h2 class="a-h2">
          <.icon name="hero-arrow-path-rounded-square" class="size-4 a-faint" /> Worktrees
          <span :if={@worktrees != []} class="a-badge">{length(@worktrees)}</span>
        </h2>
        <form
          id="create-worktree"
          phx-submit="create_worktree"
          phx-change="name_worktree"
          class="a-launcher-form"
        >
          <select name="worktree[branch]" class="a-select a-select-inline" id="worktree_branch">
            <option value="new" selected={@worktree_branch == "new"}>New branch</option>
            <option
              :for={branch <- @branches}
              value={branch.name}
              selected={branch.name == @worktree_branch}
              disabled={branch.checked_out}
            >
              {branch.name}{if branch.checked_out, do: " — in use"}
            </option>
          </select>
          <input
            :if={@worktree_branch == "new"}
            name="worktree[name]"
            value={@worktree_name}
            class="a-input a-input-inline"
            placeholder="What is it for?"
            autocomplete="off"
          />
          <button type="submit" class="a-btn" phx-disable-with="Creating…">New worktree</button>
        </form>
      </div>

      <div :if={@worktrees == []} class="a-panel a-empty">
        An isolated checkout on its own branch, so an agent can work without touching
        the files you are using. Alkim never merges one — that stays your call.
      </div>

      <div :for={%{record: worktree, work: work} <- @worktrees} class="a-panel a-worktree">
        <div class="a-worktree-head">
          <span class={[
            "a-dot",
            if(Worktrees.Worktree.active?(worktree), do: "a-dot-on", else: "a-dot-off")
          ]}></span>
          <span class="a-mono">{worktree.branch}</span>
          <span class="a-tag">from {worktree.base_branch || "detached"}</span>
          <span :if={not Worktrees.Worktree.active?(worktree)} class="a-tag">{worktree.status}</span>
        </div>

        <p class="a-mono a-faint a-truncate">{short_path(worktree.path)}</p>

        <div :if={is_map(work)} class="a-worktree-metrics">
          <span>{work.files} files changed</span>
          <span><span class="a-change-A">+{work.insertions}</span>
          <span class="a-change-D">−{work.deletions}</span></span>
          <span>{work.commits} commits</span><span :if={work.untracked > 0}>{work.untracked} untracked</span>
        </div>

        <div :if={Worktrees.Worktree.active?(worktree)} class="a-worktree-actions">
          <button
            class="a-btn a-btn-sm"
            phx-click="open_worktree_terminal"
            phx-value-id={worktree.id}
            id={"wt-terminal-#{worktree.id}"}
            disabled={@terminal_options == []}
          >
            Open terminal here
          </button>
          <button
            class="a-btn a-btn-ghost a-btn-sm"
            phx-click="keep_worktree"
            phx-value-id={worktree.id}
            id={"wt-keep-#{worktree.id}"}
            title="Remove the directory, keep the branch to merge yourself"
          >
            Keep branch
          </button>
          <button
            class="a-btn a-btn-ghost a-btn-sm a-btn-danger"
            phx-click="discard_worktree"
            phx-value-id={worktree.id}
            id={"wt-discard-#{worktree.id}"}
            data-confirm={"Remove #{worktree.branch} and everything in it?"}
          >
            Discard
          </button>
        </div>
      </div>
    </section>

    <section class="a-section" id="project-recent">
      <div class="a-section-head">
        <h2 class="a-h2"><.icon name="hero-clock" class="size-4 a-faint" /> Recent activity</h2>
      </div>
      <div class="a-panel a-rows">
        <div :if={@recent == []} class="a-empty">Finished work appears here.</div>
        <.work_row :for={entry <- @recent} entry={entry} id={"recent-#{entry.id}"} />
      </div>
    </section>
    """
  end

  defp terminal_tab(assigns) do
    ~H"""
    <section class="a-section a-term-shell" id="project-terminal">
      <div :if={@terminal_options == []} class="a-panel a-empty">
        No installed harness has a verified interactive mode yet.
      </div>

      <div :if={@terminal == nil and @terminal_options != []} class="a-panel a-empty">
        Pick a terminal from the list on the left, or open one from the <.link
          patch={~p"/projects/#{@project.id}/overview"}
          class="a-link"
        >Overview</.link>.
      </div>

      <div
        :if={@terminal}
        id={"terminal-#{@terminal.id}"}
        class="a-term-screen"
        phx-hook="EmbeddedTerminal"
        phx-update="ignore"
        data-terminal-id={@terminal.id}
      >
      </div>
    </section>
    """
  end

  @doc false
  # Controls live in the tab row, not stacked on top of the terminal: the
  # terminal is the thing being used and should not be crowded.
  defp terminal_controls(assigns) do
    ~H"""
    <div class="a-tab-actions">
      <span :if={@terminal} class="a-hint a-hide-sm">{harness_label(@terminal.harness)}</span>
      <button
        :if={@terminal && Alkim.Terminals.Terminal.live?(@terminal)}
        class="a-btn a-btn-ghost a-btn-sm"
        phx-click="stop_terminal"
        id="stop-terminal"
        title="Stop the harness"
      >
        Stop
      </button>
      <button
        :if={@terminal}
        class="a-btn a-btn-ghost a-btn-sm"
        phx-click="delete_terminal"
        phx-value-id={@terminal.id}
        id="delete-terminal"
        data-confirm="Delete this terminal and everything it printed?"
        title="Delete this terminal and its saved output"
      >
        Delete
      </button>
    </div>
    """
  end

  defp harness_label(id) do
    case Alkim.Harness.fetch_adapter(id) do
      {:ok, adapter} -> adapter.name()
      :error -> String.capitalize(id)
    end
  end

  defp git_tab(assigns) do
    ~H"""
    <section class="a-section" id="project-git">
      <div class="a-section-head">
        <h2 class="a-h2">Repository</h2>
        <button class="a-btn a-btn-ghost" phx-click="refresh_git" phx-disable-with="Reading…">
          Refresh
        </button>
      </div>

      <.async_result :let={git} assign={@git}>
        <:loading>
          <div class="a-panel a-empty">Reading the repository…</div>
        </:loading>
        <:failed :let={_reason}>
          <div class="a-panel a-empty">Could not read the repository.</div>
        </:failed>

        <div :if={git == :unavailable} class="a-panel a-empty">
          This folder is not a git repository, so Alkim cannot tell what changed.
        </div>

        <div :if={git != :unavailable} class="a-panel">
          <dl class="a-meta">
            <div>
              <dt>Branch</dt>
              <dd class="a-mono">{git.branch || "—"}</dd>
            </div>
            <div>
              <dt>Upstream</dt>
              <dd class="a-mono">{git.upstream || "none"}</dd>
            </div>
            <div :if={git.ahead || git.behind}>
              <dt>Distance</dt>
              <dd class="a-mono">↑{git.ahead || 0} ↓{git.behind || 0}</dd>
            </div>
            <div>
              <dt>Uncommitted</dt>
              <dd>{length(git.changes)} file(s)</dd>
            </div>
          </dl>
        </div>

        <div :if={git != :unavailable and git.changes != []} class="a-panel a-rows a-mt">
          <div :for={change <- Enum.take(git.changes, @change_limit)} class="a-row a-row-change">
            <span class={["a-mono", "a-change-#{String.first(change.code)}"]}>{change.code}</span>
            <span class="a-mono a-truncate">{change.path}</span>
          </div>
          <div :if={length(git.changes) > @change_limit} class="a-empty">
            and {length(git.changes) - @change_limit} more.
          </div>
        </div>

        <div :if={git != :unavailable and git.commits != []} class="a-panel a-rows a-mt">
          <div :for={commit <- git.commits} class="a-row a-row-commit">
            <span class="a-mono a-faint">{commit.hash}</span>
            <span class="a-truncate">{commit.subject}</span>
            <span class="a-muted a-truncate a-hide-sm">{commit.author}</span>
            <span class="a-faint a-hide-sm" style="text-align:right">{commit.at}</span>
          </div>
        </div>
      </.async_result>
    </section>
    """
  end

  defp settings(assigns) do
    ~H"""
    <section class="a-section" id="project-settings">
      <form class="a-form" phx-submit="rename" autocomplete="off">
        <div class="a-field">
          <label class="a-label" for="project_name">Name</label>
          <input id="project_name" name="project[name]" value={@project.name} class="a-input" />
          <span class="a-hint">Only a label. The folder on disk is never renamed.</span>
        </div>
        <div>
          <button type="submit" class="a-btn">Save</button>
        </div>
      </form>

      <dl class="a-meta a-panel a-mt">
        <div>
          <dt>Folder</dt>
          <dd class="a-mono">{@project.path}</dd>
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

      <div class="a-section-head a-mt">
        <div>
          <h2 class="a-h2">Remove project</h2>
          <p class="a-hint">
            Removes it from this list only. Nothing on disk is touched and its
            sessions stay in history.
          </p>
        </div>
        <button
          class="a-btn a-btn-danger"
          phx-click="delete"
          data-confirm={"Remove “#{@project.name}” from Alkim?"}
        >
          Remove
        </button>
      </div>
    </section>
    """
  end
end
