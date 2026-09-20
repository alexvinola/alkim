defmodule KhymeiaWeb.SessionsLive do
  @moduledoc "Every session and workflow run across projects, newest first."

  use KhymeiaWeb, :live_view

  import KhymeiaWeb.SessionComponents, only: [work_row: 1]

  alias Khymeia.{Runtime, Workflow}
  alias KhymeiaWeb.WorkEntry

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Runtime.subscribe_sessions()
      Workflow.subscribe_all()
    end

    {:ok, socket |> assign(page_title: "Sessions · Khymeia") |> load()}
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    live =
      Runtime.list_live()
      |> Enum.reject(&Khymeia.Session.terminal?(&1.status))
      |> Enum.map(&WorkEntry.from_session/1)

    live_ids = MapSet.new(live, & &1.id)

    history =
      (Runtime.list_recent(25) |> Enum.map(&WorkEntry.from_session/1)) ++
        (Workflow.list_recent(25) |> Enum.map(&WorkEntry.from_run/1))

    history = Enum.reject(history, &MapSet.member?(live_ids, &1.id))
    {active, recent} = Enum.split_with(WorkEntry.sort(live ++ history), & &1.active?)

    assign(socket, active: active, recent: recent)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} nav={@nav} active={:sessions}>
      <div class="k-page-head">
        <h1 class="k-h1">Sessions</h1>
        <div class="k-row-actions">
          <.link navigate={~p"/workflows/new"} class="k-btn">New workflow</.link>
          <.link navigate={~p"/sessions/new"} class="k-btn k-btn-primary">New session</.link>
        </div>
      </div>

      <section class="k-section" id="active-sessions">
        <div class="k-section-head">
          <h2 class="k-h2">Active</h2>
        </div>
        <div class="k-panel k-rows">
          <div :if={@active == []} class="k-empty">No active sessions.</div>
          <.work_row :for={entry <- @active} entry={entry} id={id_for(entry)} />
        </div>
      </section>

      <section class="k-section" id="recent-sessions">
        <div class="k-section-head">
          <h2 class="k-h2">Recent</h2>
        </div>
        <div class="k-panel k-rows">
          <div :if={@recent == []} class="k-empty">Finished work appears here.</div>
          <.work_row :for={entry <- @recent} entry={entry} id={recent_id(entry)} />
        </div>
      </section>
    </Layouts.app>
    """
  end

  # Workflow rows keep one id across both lists; sessions get a distinct
  # "recent-" id, which is what the history links are addressed by.
  defp id_for(%{kind: :workflow, id: id}), do: "workflow-#{id}"
  defp id_for(%{id: id}), do: "session-#{id}"

  defp recent_id(%{kind: :workflow, id: id}), do: "workflow-#{id}"
  defp recent_id(%{id: id}), do: "recent-#{id}"
end
