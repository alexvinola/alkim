defmodule AlkimWeb.SessionsLive do
  @moduledoc "Every session and workflow run across projects, newest first."

  use AlkimWeb, :live_view

  import AlkimWeb.SessionComponents, only: [work_row: 1]

  alias Alkim.{Runtime, Terminals, Workflow}
  alias AlkimWeb.WorkEntry

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Runtime.subscribe_sessions()
      Workflow.subscribe_all()
      # Terminals are sessions too, so this view has to hear about them.
      Terminals.subscribe_all()
    end

    {:ok,
     socket
     |> assign(page_title: "Sessions · Alkim", query: "", kind: "all")
     |> stream_configure(:active, dom_id: &id_for/1)
     |> stream_configure(:recent, dom_id: &recent_id/1)
     |> load()}
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_event("search", %{"search" => %{"query" => query}}, socket) do
    {:noreply, socket |> assign(:query, query) |> load()}
  end

  def handle_event("filter", %{"kind" => kind}, socket)
      when kind in ~w(all terminal session workflow) do
    {:noreply, socket |> assign(:kind, kind) |> load()}
  end

  defp matches?(entry, query, kind) do
    text = Enum.join([entry.title, entry.label, entry.workspace, entry.tag, entry.detail], " ")

    (kind == "all" or Atom.to_string(entry.kind) == kind) and
      String.contains?(String.downcase(text), String.downcase(String.trim(query)))
  end

  defp load(socket) do
    live =
      Runtime.list_live()
      |> Enum.reject(&Alkim.Session.terminal?(&1.status))
      |> Enum.map(&WorkEntry.from_session/1)

    live = live ++ Enum.map(Terminals.list_active(), &WorkEntry.from_terminal/1)
    live_ids = MapSet.new(live, & &1.id)

    history =
      (Runtime.list_recent(25) |> Enum.map(&WorkEntry.from_session/1)) ++
        (Workflow.list_recent(25) |> Enum.map(&WorkEntry.from_run/1)) ++
        (Terminals.list_recent(25) |> Enum.map(&WorkEntry.from_terminal/1))

    history = Enum.reject(history, &MapSet.member?(live_ids, &1.id))
    grouped = (live ++ history) |> WorkEntry.group() |> WorkEntry.sort()
    {active, recent} = Enum.split_with(grouped, & &1.active?)

    visible_active = Enum.filter(active, &matches?(&1, socket.assigns.query, socket.assigns.kind))
    visible_recent = Enum.filter(recent, &matches?(&1, socket.assigns.query, socket.assigns.kind))

    socket
    |> assign(
      active_count: length(active),
      recent_count: length(recent),
      visible_active_count: length(visible_active),
      visible_recent_count: length(visible_recent),
      search_form: to_form(%{"query" => socket.assigns.query}, as: :search)
    )
    |> stream(:active, visible_active, reset: true)
    |> stream(:recent, visible_recent, reset: true)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} nav={@nav} active={:sessions}>
      <div class="a-page-head">
        <div>
          <span class="a-eyebrow">Execution / history</span>
          <h1 class="a-h1">Sessions</h1>
          <p class="a-page-subtitle">
            Every terminal, task, and workflow. One place to follow the work.
          </p>
        </div>
        <div class="a-row-actions">
          <.link navigate={~p"/workflows/new"} class="a-btn" id="new-workflow-link"><.icon
            name="hero-square-3-stack-3d"
            class="size-4"
          /> New workflow</.link>
          <.link navigate={~p"/sessions/new"} class="a-btn a-btn-primary" id="new-session-link"><.icon
            name="hero-plus"
            class="size-4"
          /> New session</.link>
        </div>
      </div>

      <div class="a-filter-bar">
        <.form
          for={@search_form}
          id="session-search"
          phx-change="search"
          phx-submit="search"
          class="a-search"
          role="search"
        >
          <.icon name="hero-magnifying-glass" class="size-4 a-search-icon" />
          <.input
            field={@search_form[:query]}
            id="session-search-query"
            type="search"
            class="a-input"
            placeholder="Search tasks, models, or paths…"
            aria-label="Search sessions"
            phx-debounce="200"
          />
        </.form>
        <div class="a-filter-options" aria-label="Session type">
          <button
            :for={
              {kind, label} <- [
                {"all", "All work"},
                {"terminal", "Terminals"},
                {"session", "Sessions"},
                {"workflow", "Workflows"}
              ]
            }
            type="button"
            id={"filter-#{kind}"}
            class="a-filter-option"
            aria-pressed={to_string(@kind == kind)}
            phx-click="filter"
            phx-value-kind={kind}
          >{label}</button>
        </div>
      </div>

      <section class="a-section" id="active-sessions">
        <div class="a-section-head">
          <h2 class="a-h2">
            <.icon name="hero-bolt" class="size-4 a-faint" /> Active
            <span class="a-tag">{@visible_active_count} / {@active_count}</span>
          </h2><span class="a-hint">Updates live</span>
        </div>
        <div class="a-panel a-rows" id="active-session-list" phx-update="stream">
          <div id="active-sessions-empty" class="hidden only:block a-empty">
            {if @active_count == 0,
              do: "No active sessions. Start a task to see it here.",
              else: "No active sessions match your filters."}
          </div>
          <.work_row :for={{id, entry} <- @streams.active} entry={entry} id={id} />
        </div>
      </section>

      <section class="a-section" id="recent-sessions">
        <div class="a-section-head">
          <h2 class="a-h2">
            <.icon name="hero-clock" class="size-4 a-faint" /> Recent
            <span class="a-tag">{@visible_recent_count} / {@recent_count}</span>
          </h2><span class="a-hint">Latest activity across projects</span>
        </div>
        <div class="a-panel a-rows" id="recent-session-list" phx-update="stream">
          <div id="recent-sessions-empty" class="hidden only:block a-empty">
            {if @recent_count == 0,
              do: "Finished work appears here.",
              else: "No recent sessions match your filters."}
          </div>
          <.work_row :for={{id, entry} <- @streams.recent} entry={entry} id={id} />
        </div>
      </section>
    </Layouts.app>
    """
  end

  # Workflow rows keep one id across both lists; sessions get a distinct
  # "recent-" id, which is what the history links are addressed by.
  defp id_for(%{kind: :workflow, id: id}), do: "workflow-#{id}"
  defp id_for(%{kind: :terminal, id: id}), do: "terminal-#{id}"
  defp id_for(%{id: id}), do: "session-#{id}"

  defp recent_id(%{kind: :workflow, id: id}), do: "workflow-#{id}"
  defp recent_id(%{kind: :terminal, id: id}), do: "terminal-#{id}"
  defp recent_id(%{id: id}), do: "recent-#{id}"
end
