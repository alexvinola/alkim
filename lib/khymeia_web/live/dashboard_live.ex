defmodule KhymeiaWeb.DashboardLive do
  @moduledoc "Installed harnesses, live sessions and recent history."

  use KhymeiaWeb, :live_view

  import KhymeiaWeb.SessionComponents

  alias Khymeia.Runtime

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Runtime.subscribe_sessions()
      Runtime.subscribe_harnesses()
      Khymeia.Workflow.subscribe_all()
    end

    {:ok,
     socket
     |> assign(page_title: "Khymeia", harnesses: Runtime.harnesses())
     |> load_sessions()
     |> load_workflows()}
  end

  @impl true
  def handle_event("refresh_harnesses", _params, socket) do
    {:noreply, assign(socket, harnesses: Runtime.refresh_harnesses())}
  end

  @impl true
  def handle_info({:session_event, _event}, socket), do: {:noreply, load_sessions(socket)}

  def handle_info({:workflow_event, _event}, socket), do: {:noreply, load_workflows(socket)}

  def handle_info({:harnesses, harnesses}, socket),
    do: {:noreply, assign(socket, harnesses: harnesses)}

  defp load_workflows(socket) do
    {active, done} =
      Khymeia.Workflow.list_recent(15) |> Enum.split_with(&Khymeia.Workflow.Run.active?/1)

    assign(socket, workflows: active ++ done)
  end

  defp load_sessions(socket) do
    live = Runtime.list_live()
    active = Enum.reject(live, &Khymeia.Session.terminal?(&1.status))
    active_ids = MapSet.new(active, & &1.id)
    recent = Runtime.list_recent(15) |> Enum.reject(&MapSet.member?(active_ids, &1.id))

    assign(socket, active: active, recent: recent)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:dashboard}>
      <section class="k-section" id="harnesses">
        <div class="k-section-head">
          <h2 class="k-h2">Installed harnesses</h2>
          <button
            class="k-btn k-btn-ghost"
            phx-click="refresh_harnesses"
            phx-disable-with="Scanning…"
          >
            Rescan
          </button>
        </div>
        <div class="k-panel k-rows">
          <div :if={@harnesses == []} class="k-empty">Scanning for harnesses…</div>
          <div :for={h <- @harnesses} class="k-row k-row-harness" id={"harness-#{h.id}"}>
            <span class={["k-check", check_class(h.status)]}>{check_mark(h.status)}</span>
            <span>{h.name}</span>
            <span class="k-mono k-faint k-truncate k-hide-sm">
              {h.executable && short_path(h.executable)}{h.version && "  ·  #{h.version}"}
            </span>
            <span class="k-muted">{status_label(h.status)}</span>
          </div>
        </div>
      </section>

      <section class="k-section" id="workflows">
        <div class="k-section-head">
          <h2 class="k-h2">Workflows</h2>
          <.link navigate={~p"/workflows/new"} class="k-btn">New workflow</.link>
        </div>
        <div class="k-panel k-rows">
          <div :if={@workflows == []} class="k-empty">No workflows yet.</div>
          <.link
            :for={w <- @workflows}
            navigate={~p"/workflows/#{w.id}"}
            class="k-row k-row-session"
            id={"workflow-#{w.id}"}
          >
            <span>{w.title || w.name}</span>
            <span class="k-truncate">{w.task |> String.split("\n") |> hd()}</span>
            <span class="k-mono k-faint k-truncate k-hide-sm">
              {if w.current_step,
                do: "#{w.current_step} · it. #{w.iteration}",
                else: short_path(w.workspace)}
            </span>
            <.status status={w.status} />
            <span class="k-hide-sm" style="text-align:right">
              <%= if Khymeia.Workflow.Run.active?(w) do %>
                <.elapsed id={"wf-elapsed-#{w.id}"} since={w.started_at} />
              <% else %>
                <span class="k-mono k-muted">{format_duration(w.started_at, w.completed_at)}</span>
              <% end %>
            </span>
          </.link>
        </div>
      </section>

      <section class="k-section" id="active-sessions">
        <div class="k-section-head">
          <h2 class="k-h2">Active sessions</h2>
          <.link navigate={~p"/sessions/new"} class="k-btn">New session</.link>
        </div>
        <div class="k-panel k-rows">
          <div :if={@active == []} class="k-empty">No active sessions.</div>
          <.link
            :for={s <- @active}
            navigate={~p"/sessions/#{s.id}"}
            class="k-row k-row-session"
            id={"session-#{s.id}"}
          >
            <span>
              {harness_name(s.harness)}
              <span :if={role = s.metadata["role"]} class="k-tag">{role}</span>
            </span>
            <span class="k-truncate">{Khymeia.Session.title(s)}</span>
            <span class="k-mono k-faint k-truncate k-hide-sm">{short_path(s.workspace)}</span>
            <.status status={s.status} />
            <span class="k-hide-sm" style="text-align:right"><.elapsed
              id={"elapsed-#{s.id}"}
              since={s.started_at}
            /></span>
          </.link>
        </div>
      </section>

      <section class="k-section" id="recent-sessions">
        <div class="k-section-head">
          <h2 class="k-h2">Recent</h2>
        </div>
        <div class="k-panel k-rows">
          <div :if={@recent == []} class="k-empty">Finished sessions appear here.</div>
          <.link
            :for={s <- @recent}
            navigate={~p"/sessions/#{s.id}"}
            class="k-row k-row-session"
            id={"recent-#{s.id}"}
          >
            <span>{harness_name(s.harness)}</span>
            <span class="k-truncate">{Khymeia.Session.title(s)}</span>
            <span class="k-mono k-faint k-truncate k-hide-sm">{short_path(s.workspace)}</span>
            <.status status={s.status} />
            <span class="k-mono k-muted k-hide-sm" style="text-align:right">
              {format_duration(s.started_at, s.completed_at)}
            </span>
          </.link>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp check_mark(:available), do: "✓"
  defp check_mark(:no_adapter), do: "◐"
  defp check_mark(:not_installed), do: "○"

  defp check_class(:available), do: "k-check-yes"
  defp check_class(:no_adapter), do: "k-check-partial"
  defp check_class(:not_installed), do: "k-check-no"

  defp status_label(:available), do: "ready"
  defp status_label(:no_adapter), do: "installed · no adapter yet"
  defp status_label(:not_installed), do: "not installed"
end
