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

  alias Khymeia.{Git, Projects, Runtime, Terminals, Workflow, Worktrees}
  alias KhymeiaWeb.{HarnessOptions, WorkEntry}

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
           page_title: "#{project.name} · Khymeia"
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

  def handle_event("name_worktree", %{"worktree" => %{"name" => name}}, socket),
    do: {:noreply, assign(socket, worktree_name: name)}

  def handle_event("create_worktree", %{"worktree" => %{"name" => name}}, socket) do
    case Worktrees.create(socket.assigns.project, name) do
      {:ok, _worktree} ->
        {:noreply, socket |> assign(worktree_name: "") |> load_worktrees()}

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
    do: {:noreply, assign(socket, terminal_harness: harness)}

  # The browser attached: replay what it missed before it started listening.
  def handle_event("terminal_attached", _params, %{assigns: %{terminal: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("terminal_attached", _params, socket) do
    case Terminals.attach(socket.assigns.terminal.id) do
      {:ok, terminal, scrollback} ->
        # Replay from a clean screen: live output may already have been
        # painted between subscribing and the client attaching, and the
        # scrollback contains it too.
        socket = assign(socket, terminal: terminal)
        {:noreply, write(socket, terminal.id, scrollback, reset: true)}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("terminal_keys", %{"data" => data}, socket) do
    if socket.assigns.terminal, do: Terminals.send_keys(socket.assigns.terminal.id, data)
    {:noreply, socket}
  end

  def handle_event("terminal_resize", %{"rows" => rows, "cols" => cols}, socket) do
    if socket.assigns.terminal, do: Terminals.resize(socket.assigns.terminal.id, rows, cols)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:terminal_output, id, data}, socket),
    do: {:noreply, write(socket, id, data)}

  def handle_info({:terminal_status, terminal}, socket) do
    socket =
      if socket.assigns.terminal && socket.assigns.terminal.id == terminal.id,
        do: assign(socket, terminal: terminal),
        else: socket

    {:noreply, socket |> load() |> load_terminals()}
  end

  def handle_info(:worktrees_changed, socket), do: {:noreply, load_worktrees(socket)}

  def handle_info(_message, socket), do: {:noreply, load(socket)}

  ## Loading

  defp assign_options(socket) do
    options = HarnessOptions.interactive(HarnessOptions.build(socket.assigns.nav.harnesses))

    assign(socket,
      terminal_options: options,
      terminal_harness: socket.assigns.terminal_harness || HarnessOptions.first_value(options)
    )
  end

  defp load(%{assigns: %{project: project}} = socket) do
    live =
      Runtime.list_live()
      |> Enum.filter(&(&1[:project_id] == project.id))
      |> Enum.reject(&Khymeia.Session.terminal?(&1.status))
      |> Enum.map(&WorkEntry.from_session/1)

    live_ids = MapSet.new(live, & &1.id)

    terminals =
      project.id |> Terminals.list_for_project(20) |> Enum.map(&WorkEntry.from_terminal/1)

    history =
      (Runtime.list_recent_for_project(project.id, 20) |> Enum.map(&WorkEntry.from_session/1)) ++
        (Workflow.list_recent_for_project(project.id, 20) |> Enum.map(&WorkEntry.from_run/1)) ++
        terminals

    history = Enum.reject(history, &MapSet.member?(live_ids, &1.id))
    {active, recent} = Enum.split_with(WorkEntry.sort(live ++ history), & &1.active?)

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
  # git rather than from anything Khymeia recorded.
  defp load_worktrees(%{assigns: %{project: project}} = socket) do
    worktrees =
      project.id
      |> Worktrees.list_for_project(12)
      |> Enum.map(&%{record: &1, work: Worktrees.work(&1)})

    assign(socket, worktrees: worktrees)
  end

  defp load_terminals(%{assigns: %{project: project}} = socket),
    do: assign(socket, terminals: Terminals.list_for_project(project.id, 8))

  # One subscription at a time: a view only ever paints the terminal it shows.
  defp attach(socket, terminal) do
    current = socket.assigns.terminal
    if current && current.id != terminal.id, do: Terminals.unsubscribe(current.id)

    if connected?(socket) and (is_nil(current) or current.id != terminal.id) do
      Terminals.subscribe(terminal.id)
    end

    assign(socket, terminal: terminal)
  end

  defp write(socket, id, data, opts \\ [])

  defp write(socket, id, data, opts) when byte_size(data) > 0 do
    push_event(socket, "terminal:write", %{
      id: id,
      data: Base.encode64(data),
      reset: Keyword.get(opts, :reset, false)
    })
  end

  defp write(socket, id, _data, opts) do
    if Keyword.get(opts, :reset, false),
      do: push_event(socket, "terminal:write", %{id: id, data: "", reset: true}),
      else: socket
  end

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

      <div class="k-tabs-row">
        <nav class="k-tabs k-tabs-page" aria-label="Project">
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
            {label}
          </.link>
        </nav>

        <.terminal_controls :if={@tab == "terminal"} terminal={@terminal} />
      </div>

      <div :if={@tab == "terminal" and @terminals != []} class="k-term-tabs">
        <button
          :for={entry <- @terminals}
          type="button"
          phx-click="select_terminal"
          phx-value-id={entry.id}
          id={"term-tab-#{entry.id}"}
          class={[
            "k-term-tab",
            @terminal && @terminal.id == entry.id && "k-term-tab-on",
            not Khymeia.Terminals.Terminal.live?(entry) && "k-term-dead"
          ]}
        >
          <span class={["k-dot", live_dot(entry)]}></span>
          {harness_label(entry.harness)}
        </button>
      </div>

      <.overview :if={@tab == "overview"} {assigns} />
      <.terminal_tab :if={@tab == "terminal"} {assigns} />
      <.git_tab :if={@tab == "git"} {assigns} />
      <.settings :if={@tab == "settings"} {assigns} />
    </Layouts.app>
    """
  end

  defp overview(assigns) do
    ~H"""
    <section class="k-section">
      <div class="k-launcher">
        <form
          id="open-terminal"
          phx-submit="open_terminal"
          phx-change="pick_terminal_harness"
          class="k-launcher-form"
        >
          <.icon name="hero-command-line" class="size-4 k-faint" />
          <select name="terminal[harness]" class="k-select k-select-inline" id="overview_harness">
            <option
              :for={option <- @terminal_options}
              value={option.value}
              selected={option.value == @terminal_harness}
            >
              {option.label}
            </option>
          </select>
          <button
            type="submit"
            class="k-btn k-btn-primary"
            disabled={@terminal_options == []}
            phx-disable-with="Opening…"
            id="overview-open-terminal"
          >
            Open terminal
          </button>
        </form>

        <span class="k-spacer" style="flex:1"></span>

        <span class="k-hint k-hide-sm">Headless, for automation:</span>
        <.link navigate={~p"/sessions/new?project=#{@project.id}"} class="k-btn">Session</.link>
        <.link navigate={~p"/workflows/new?project=#{@project.id}"} class="k-btn">Workflow</.link>
      </div>

      <p :if={@terminal_options == []} class="k-hint" style="margin-top:.6rem">
        No installed harness has a verified interactive mode yet.
      </p>
    </section>

    <section class="k-section" id="project-active">
      <div class="k-section-head">
        <h2 class="k-h2">Active <span class="k-badge">{length(@active)}</span></h2>
      </div>
      <div :if={@active == []} class="k-panel k-empty">
        Nothing running in this project. Open a terminal to work with an agent directly.
      </div>
      <div class="k-grid">
        <.work_card :for={entry <- @active} entry={entry} />
      </div>
    </section>

    <section class="k-section" id="project-worktrees">
      <div class="k-section-head">
        <h2 class="k-h2">
          Worktrees <span :if={@worktrees != []} class="k-badge">{length(@worktrees)}</span>
        </h2>
        <form
          id="create-worktree"
          phx-submit="create_worktree"
          phx-change="name_worktree"
          class="k-launcher-form"
        >
          <input
            name="worktree[name]"
            value={@worktree_name}
            class="k-input k-input-inline"
            placeholder="What is it for?"
            autocomplete="off"
          />
          <button type="submit" class="k-btn" phx-disable-with="Creating…">New worktree</button>
        </form>
      </div>

      <div :if={@worktrees == []} class="k-panel k-empty">
        An isolated checkout on its own branch, so an agent can work without touching
        the files you are using. Khymeia never merges one — that stays your call.
      </div>

      <div :for={%{record: worktree, work: work} <- @worktrees} class="k-panel k-worktree">
        <div class="k-worktree-head">
          <span class={[
            "k-dot",
            if(Worktrees.Worktree.active?(worktree), do: "k-dot-on", else: "k-dot-off")
          ]}></span>
          <span class="k-mono">{worktree.branch}</span>
          <span class="k-tag">from {worktree.base_branch || "detached"}</span>
          <span :if={not Worktrees.Worktree.active?(worktree)} class="k-tag">{worktree.status}</span>
        </div>

        <p class="k-mono k-faint k-truncate">{short_path(worktree.path)}</p>

        <p :if={is_map(work)} class="k-hint">
          {work.files} file(s) · <span class="k-change-A">+{work.insertions}</span>
          <span class="k-change-D">−{work.deletions}</span>
          · {work.commits} commit(s)<span :if={work.untracked > 0}>
            · {work.untracked} untracked
          </span>
        </p>

        <div :if={Worktrees.Worktree.active?(worktree)} class="k-worktree-actions">
          <button
            class="k-btn k-btn-sm"
            phx-click="open_worktree_terminal"
            phx-value-id={worktree.id}
            id={"wt-terminal-#{worktree.id}"}
            disabled={@terminal_options == []}
          >
            Open terminal here
          </button>
          <button
            class="k-btn k-btn-ghost k-btn-sm"
            phx-click="keep_worktree"
            phx-value-id={worktree.id}
            id={"wt-keep-#{worktree.id}"}
            title="Remove the directory, keep the branch to merge yourself"
          >
            Keep branch
          </button>
          <button
            class="k-btn k-btn-ghost k-btn-sm k-btn-danger"
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

  defp terminal_tab(assigns) do
    ~H"""
    <section class="k-section k-term-shell" id="project-terminal">
      <div :if={@terminal_options == []} class="k-panel k-empty">
        No installed harness has a verified interactive mode yet.
      </div>

      <div :if={@terminal == nil and @terminal_options != []} class="k-panel k-empty">
        Pick a terminal from this project, or open one from the <.link
          patch={~p"/projects/#{@project.id}/overview"}
          class="k-link"
        >Overview</.link>.
      </div>

      <div
        :if={@terminal}
        id={"terminal-#{@terminal.id}"}
        class="k-term-screen"
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
    <div class="k-tab-actions">
      <span :if={@terminal} class="k-hint k-hide-sm">{harness_label(@terminal.harness)}</span>
      <button
        :if={@terminal && Khymeia.Terminals.Terminal.live?(@terminal)}
        class="k-btn k-btn-ghost k-btn-sm"
        phx-click="stop_terminal"
        id="stop-terminal"
        title="Stop the harness"
      >
        Stop
      </button>
      <button
        :if={@terminal}
        class="k-btn k-btn-ghost k-btn-sm"
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

  defp live_dot(entry),
    do: if(Khymeia.Terminals.Terminal.live?(entry), do: "k-dot-on", else: "k-dot-off")

  defp harness_label(id) do
    case Khymeia.Harness.fetch_adapter(id) do
      {:ok, adapter} -> adapter.name()
      :error -> String.capitalize(id)
    end
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
