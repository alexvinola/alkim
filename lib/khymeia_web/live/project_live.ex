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

  alias Khymeia.{Git, Projects, Runtime, Terminals, Workflow}
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
    end

    {:ok,
     assign(socket,
       terminal: nil,
       terminals: [],
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
    case Terminals.get(id) do
      nil -> {:noreply, socket}
      terminal -> {:noreply, attach(socket, terminal)}
    end
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

  # Continues the same conversation in a new terminal: the old process is
  # gone, but the harness kept the conversation itself.
  def handle_event("resume_terminal", %{"id" => id}, socket) do
    with %{} = old <- Terminals.get(id),
         {:ok, terminal} <-
           Terminals.start(%{
             "harness" => harness_choice(old),
             "workspace" => old.workspace,
             "model" => old.model,
             "permission_mode" => old.permission_mode,
             "resume" => old.harness_ref || "last"
           }) do
      {:noreply, socket |> load() |> load_terminals() |> attach(terminal)}
    else
      {:error, {:invalid, errors}} ->
        {:noreply, put_flash(socket, :error, "Could not resume: #{describe(errors)}")}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not resume that conversation")}
    end
  end

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
      terminal -> attach(socket, terminal)
    end
  end

  defp maybe_load_terminals(socket, _params), do: load_terminals(socket)

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
      <div class="k-term-bar">
        <div class="k-term-tabs">
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

        <span class="k-spacer" style="flex:1"></span>

        <form
          id="open-terminal-tab"
          phx-submit="open_terminal"
          phx-change="pick_terminal_harness"
          class="k-term-bar"
        >
          <select name="terminal[harness]" class="k-select k-select-inline" id="terminal_harness">
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
            class="k-btn"
            disabled={@terminal_options == []}
            phx-disable-with="Opening…"
          >
            New terminal
          </button>
        </form>

        <button
          :if={@terminal && Khymeia.Terminals.Terminal.live?(@terminal)}
          class="k-btn k-btn-danger"
          phx-click="stop_terminal"
          id="stop-terminal"
        >
          Stop
        </button>

        <button
          :if={@terminal}
          class="k-btn k-btn-ghost"
          phx-click="delete_terminal"
          phx-value-id={@terminal.id}
          id="delete-terminal"
          data-confirm="Delete this terminal and everything it printed?"
        >
          Delete
        </button>
      </div>

      <div :if={@terminal_options == []} class="k-panel k-empty">
        No installed harness has a verified interactive mode.
      </div>

      <div :if={@terminal == nil and @terminal_options != []} class="k-panel k-empty">
        Open a terminal to run the harness's own interface in <span class="k-mono">{short_path(@project.path)}</span>. Khymeia supervises the
        process; the CLI keeps all of its own commands.
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

      <div :if={@terminal && not Khymeia.Terminals.Terminal.live?(@terminal)} class="k-term-bar">
        <span class="k-hint">
          {exit_summary(@terminal)} Its output above was read from disk. Resuming asks {harness_label(
            @terminal.harness
          )} to reopen the conversation — it can only do so
          if the CLI saved one.
        </span>
        <button
          class="k-btn"
          phx-click="resume_terminal"
          phx-value-id={@terminal.id}
          id="resume-terminal"
          phx-disable-with="Resuming…"
        >
          Resume conversation
        </button>
      </div>
    </section>
    """
  end

  defp live_dot(entry),
    do: if(Khymeia.Terminals.Terminal.live?(entry), do: "k-dot-on", else: "k-dot-off")

  # A terminal Khymeia never saw finish (it was killed with the runtime) has
  # no exit code, and saying "status " would be worse than saying nothing.
  defp exit_summary(%{exit_code: nil}), do: "This terminal is no longer running."
  defp exit_summary(%{exit_code: code}), do: "This terminal exited with status #{code}."

  defp harness_choice(%{harness: harness, provider_profile_id: nil}), do: harness
  defp harness_choice(%{harness: harness, provider_profile_id: id}), do: "#{harness}@#{id}"

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
