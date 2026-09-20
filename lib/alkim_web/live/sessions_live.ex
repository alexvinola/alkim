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

    {:ok, socket |> assign(page_title: "Sessions · Alkim") |> load()}
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    live =
      Runtime.list_live()
      |> Enum.reject(&Alkim.Session.terminal?(&1.status))
      |> Enum.map(&WorkEntry.from_session/1)

    live_ids = MapSet.new(live, & &1.id)

    history =
      (Runtime.list_recent(25) |> Enum.map(&WorkEntry.from_session/1)) ++
        (Workflow.list_recent(25) |> Enum.map(&WorkEntry.from_run/1)) ++
        (Terminals.list_recent(25) |> Enum.map(&WorkEntry.from_terminal/1))

    history = Enum.reject(history, &MapSet.member?(live_ids, &1.id))
    {active, recent} = Enum.split_with(WorkEntry.sort(live ++ history), & &1.active?)

    assign(socket, active: active, recent: recent)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} nav={@nav} active={:sessions}>
      <div class="a-page-head">
        <h1 class="a-h1">Sessions</h1>
        <div class="a-row-actions">
          <.link navigate={~p"/workflows/new"} class="a-btn">New workflow</.link>
          <.link navigate={~p"/sessions/new"} class="a-btn a-btn-primary">New session</.link>
        </div>
      </div>

      <section class="a-section" id="active-sessions">
        <div class="a-section-head">
          <h2 class="a-h2">Active</h2>
        </div>
        <div class="a-panel a-rows">
          <div :if={@active == []} class="a-empty">No active sessions.</div>
          <.work_row :for={entry <- @active} entry={entry} id={id_for(entry)} />
        </div>
      </section>

      <section class="a-section" id="recent-sessions">
        <div class="a-section-head">
          <h2 class="a-h2">Recent</h2>
        </div>
        <div class="a-panel a-rows">
          <div :if={@recent == []} class="a-empty">Finished work appears here.</div>
          <.work_row :for={entry <- @recent} entry={entry} id={recent_id(entry)} />
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
