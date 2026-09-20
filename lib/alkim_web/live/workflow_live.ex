defmodule AlkimWeb.WorkflowLive do
  @moduledoc """
  A workflow run, laid out like a project: a header that never moves, then
  tabs over what the run is made of — its timeline, its steps, the agents it
  started, what it changed, and how its roles are mapped.

  What stays *above* the tabs is deliberate: status and a human checkpoint
  are the things a run needs you for, and they must never be hidden behind a
  tab you did not happen to open.

  Workflow events only say *that* something changed; the view re-reads the
  persisted run, which is the source of truth. No polling.
  """

  use AlkimWeb, :live_view

  import AlkimWeb.SessionComponents

  alias Alkim.{Runtime, Terminals, Workflow, Worktrees}
  alias Alkim.Runtime.Event
  alias Alkim.Workflow.{Role, Run, Timeline}

  @tabs ~w(timeline steps agents changes roles)

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: Workflow.subscribe(id)

    case Workflow.get(id) do
      {:ok, run, steps} ->
        {:ok,
         socket
         |> assign(
           reply: "",
           tab: "timeline",
           agent: nil,
           agent_events: [],
           project: Alkim.Projects.get(run.project_id)
         )
         |> assign_run(run, steps)}

      :error ->
        {:ok, socket |> put_flash(:error, "Workflow not found") |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = if params["tab"] in @tabs, do: params["tab"], else: "timeline"

    # On the agents tab, show one agent's own output: the run seen through
    # the eyes of whoever is doing the work, not merged with everyone else.
    wanted =
      if tab == "agents",
        do: params["a"] || socket.assigns.agent || default_agent(socket.assigns.agents),
        else: nil

    {:noreply, socket |> assign(tab: tab) |> watch_agent(wanted)}
  end

  # The implementer is the one a human talks to, so it is what opens first.
  defp default_agent([]), do: nil

  defp default_agent(agents) do
    agent = Enum.find(agents, &(&1.role == "implementer")) || List.first(agents)
    agent.session_id
  end

  defp watch_agent(%{assigns: %{agent: same}} = socket, same) when not is_nil(same), do: socket

  defp watch_agent(socket, nil) do
    if socket.assigns.agent, do: Runtime.unsubscribe_session(socket.assigns.agent)
    assign(socket, agent: nil, agent_events: [])
  end

  defp watch_agent(socket, session_id) do
    if socket.assigns.agent, do: Runtime.unsubscribe_session(socket.assigns.agent)
    if connected?(socket), do: Runtime.subscribe_session(session_id)

    case Runtime.get_session(session_id) do
      {:ok, session, events} ->
        assign(socket,
          agent: session_id,
          agent_session: session,
          agent_events: events,
          agent_harness: harness_name(session.harness)
        )

      :error ->
        assign(socket, agent: nil, agent_events: [])
    end
  end

  @impl true
  def handle_info({:workflow_event, _event}, socket), do: {:noreply, reload(socket)}

  # Only the agent being watched: a run has several, and a view shows one.
  def handle_info({:session_event, %Event{session_id: id} = event}, socket)
      when id == socket.assigns.agent do
    {:noreply, assign(socket, agent_events: socket.assigns.agent_events ++ [event])}
  end

  def handle_info({:session_event, _event}, socket), do: {:noreply, socket}

  @impl true
  def handle_event("stop", _, socket), do: act(socket, Workflow.stop(socket.assigns.run.id))
  def handle_event("resume", _, socket), do: act(socket, Workflow.resume(socket.assigns.run.id))

  def handle_event("complete", _, socket),
    do: act(socket, Workflow.complete(socket.assigns.run.id))

  @doc false
  # Opens the harness's *own* interface on this agent's conversation. Never
  # while the workflow is mid-turn on it: two clients on one conversation is
  # how you corrupt it.
  def handle_event("open_agent_terminal", %{"id" => session_id}, socket) do
    agent = Enum.find(socket.assigns.agents, &(&1.session_id == session_id))

    cond do
      is_nil(agent) or is_nil(agent.harness_ref) ->
        {:noreply,
         put_flash(socket, :error, "This agent has no conversation the CLI can reopen yet.")}

      agent.busy? ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "That agent is mid-turn. Wait for it to finish, or stop the run."
         )}

      true ->
        attrs = %{
          "harness" => agent.harness,
          "worktree" => socket.assigns.run.worktree_id,
          "workspace" => socket.assigns.run.workspace,
          "model" => agent.model,
          "resume" => agent.harness_ref
        }

        case Terminals.start(attrs) do
          {:ok, terminal} ->
            {:noreply,
             push_navigate(socket,
               to: ~p"/projects/#{socket.assigns.run.project_id}/terminal?t=#{terminal.id}"
             )}

          {:error, {:invalid, errors}} ->
            {:noreply, put_flash(socket, :error, Enum.map_join(errors, "; ", fn {_, m} -> m end))}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Could not open the CLI: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("reply_change", %{"reply" => reply}, socket),
    do: {:noreply, assign(socket, reply: reply)}

  def handle_event("reply", %{"reply" => reply}, socket) do
    case Workflow.resume(socket.assigns.run.id, %{reply: reply}) do
      :ok -> {:noreply, socket |> assign(reply: "") |> reload()}
      error -> act(socket, error)
    end
  end

  defp act(socket, :ok), do: {:noreply, reload(socket)}

  defp act(socket, {:error, :reply_required}),
    do: {:noreply, put_flash(socket, :error, "Write an answer first.")}

  defp act(socket, {:error, :not_running}),
    do: {:noreply, socket |> put_flash(:error, "The workflow is no longer running.") |> reload()}

  defp act(socket, {:error, reason}),
    do: {:noreply, put_flash(socket, :error, "Error: #{inspect(reason)}")}

  defp reload(socket) do
    case Workflow.get(socket.assigns.run.id) do
      {:ok, run, steps} -> socket |> assign_run(run, steps) |> follow_first_agent()
      :error -> socket
    end
  end

  # A run usually has no agent yet when its page opens; the first one to
  # start is the one to show.
  defp follow_first_agent(%{assigns: %{tab: "agents", agent: nil}} = socket),
    do: watch_agent(socket, default_agent(socket.assigns.agents))

  defp follow_first_agent(socket), do: socket

  defp assign_run(socket, run, steps) do
    children = Enum.group_by(Enum.filter(steps, & &1.parent_id), & &1.parent_id)
    top = Enum.filter(steps, &(&1.kind == :step))
    ran = MapSet.new(top, & &1.step)

    pending =
      if Run.active?(run),
        do:
          for(
            %{"id" => id, "role" => role} <- run.definition["steps"],
            id not in ran,
            do: {id, role}
          ),
        else: []

    assign(socket,
      page_title: "#{title(run)} · Alkim",
      run: run,
      top: top,
      children: children,
      pending: pending,
      timeline: Timeline.build(run, steps),
      live: Workflow.alive?(run.id),
      agents: agents(steps),
      sidebar: sidebar(steps),
      worktree: Worktrees.get(run.worktree_id)
    )
  end

  @doc false
  # The run seen as "who did the work" rather than "what happened". A role
  # keeps one conversation across several steps — the implementer's fix
  # continues the session that implemented — so agents are grouped by
  # session, not by step. The newest step stands for the agent's state.
  def agents(steps) do
    steps
    |> Enum.filter(& &1.session_id)
    |> Enum.group_by(& &1.session_id)
    |> Enum.map(fn {session_id, for_session} ->
      [latest | _] = Enum.sort_by(for_session, &{&1.started_at, &1.inserted_at}, :desc)

      %{
        session_id: session_id,
        workflow_id: latest.workflow_id,
        harness_ref: harness_ref(session_id),
        busy?: latest.status in [:running],
        role: latest.role,
        harness: latest.harness,
        model: latest.model,
        status: latest.status,
        steps: length(for_session),
        started_at: Enum.min_by(for_session, & &1.inserted_at).started_at,
        completed_at: latest.completed_at,
        label: agent_label(latest)
      }
    end)
    |> Enum.sort_by(& &1.started_at, {:asc, DateTime})
  end

  # The harness's own conversation id, which is what the real CLI resumes.
  # Read from the record, never by calling the session process: this runs
  # for every agent on every render, and a busy agent must not be able to
  # stall the page that is watching it.
  defp harness_ref(session_id) do
    case Alkim.Sessions.get(session_id) do
      %{harness_ref: ref} -> ref
      nil -> nil
    end
  end

  defp agent_label(%{role: role}) when is_binary(role) do
    Role.title(String.to_existing_atom(role))
  rescue
    ArgumentError -> role
  end

  defp agent_label(step), do: step_label(step)

  defp sidebar(steps) do
    for agent <- agents(steps) do
      %{
        id: agent.session_id,
        kind: :session,
        title: agent.label,
        status: agent.status,
        path: ~p"/workflows/#{agent.workflow_id}/agents?#{[a: agent.session_id]}"
      }
    end
  end

  defp title(run),
    do: run.task |> String.split("\n", trim: true) |> List.first("") |> String.slice(0, 70)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      nav={@nav}
      active={:sessions}
      project={@project}
      sessions={@sidebar}
      sessions_title="Agents"
    >
      <div class="a-page-head">
        <div style="min-width:0">
          <span class="a-h2">Workflow · {@run.title || @run.name}</span>
          <h1 class="a-h1 a-truncate">{title(@run)}</h1>
        </div>
        <button
          :if={@live and Run.active?(@run)}
          class="a-btn a-btn-danger"
          phx-click="stop"
          id="stop-workflow"
          data-confirm="Stop this workflow and every agent it started?"
        >
          Stop
        </button>
      </div>

      <section class="a-section">
        <div class="a-panel">
          <dl class="a-meta" id="workflow-meta">
            <div>
              <dt>Status</dt><dd id="workflow-status"><.status status={@run.status} /></dd>
            </div>
            <div>
              <dt>Iteration</dt><dd>{@run.iteration} / {@run.max_iterations}</dd>
            </div>
            <div>
              <dt>Isolation</dt>
              <dd class="a-mono a-truncate">
                {if @worktree, do: @worktree.branch, else: "project folder"}
              </dd>
            </div>
            <div>
              <dt>Duration</dt>
              <dd>
                <.elapsed id="workflow-elapsed" since={@run.started_at} until={@run.completed_at} />
              </dd>
            </div>
            <div>
              <dt>Advisor calls</dt><dd>{@run.advisor_calls}</dd>
            </div>
          </dl>
          <div :if={@run.error} class="a-banner a-banner-error" style="margin:0 1rem 1rem">
            {@run.error}
          </div>
          <.checkpoint :if={@run.status == :waiting and @live} run={@run} reply={@reply} />
          <div :if={@run.status == :waiting and not @live} class="a-banner" style="margin:0 1rem 1rem">
            Waiting, but the workflow process is gone; it cannot be resumed.
          </div>
        </div>
      </section>

      <div class="a-tabs-row">
        <nav class="a-tabs a-tabs-page" aria-label="Workflow">
          <.link
            :for={
              {tab, label} <- [
                {"timeline", "Timeline"},
                {"steps", "Steps"},
                {"agents", "Agents"},
                {"changes", "Changes"},
                {"roles", "Roles"}
              ]
            }
            patch={~p"/workflows/#{@run.id}/#{tab}"}
            aria-current={@tab == tab && "page"}
          >
            {label}
          </.link>
        </nav>
      </div>

      <section :if={@tab == "timeline"} class="a-section">
        <div class="a-panel a-activity" id="workflow-timeline" phx-hook="FollowTail">
          <div
            :for={e <- @timeline}
            id={"tl-#{e.id}"}
            class={["a-ev a-msg", "a-who-#{e.who}", "a-tone-#{e.tone}"]}
          >
            <span class="a-ev-time">{time(e.at)}</span>
            <div class="a-ev-body"><span class="a-who">{who(e.who)}</span>{e.text}</div>
          </div>
        </div>
      </section>

      <section :if={@tab == "steps"} class="a-section">
        <div class="a-panel a-tree" id="workflow-steps">
          <div :for={step <- @top} class="a-tree-item" id={"step-#{step.id}"}>
            <div class="a-step-line"><.step_line step={step} /></div>
            <div
              :for={child <- Map.get(@children, step.id, [])}
              class="a-tree-child a-step-line"
              id={"step-#{child.id}"}
            >
              <span class="a-faint">└─</span> <.step_line step={child} />
            </div>
          </div>
          <div
            :for={{id, role} <- @pending}
            class="a-tree-item a-step-line a-faint"
            id={"pending-#{id}"}
          >
            <span class="a-step-mark">○</span> {step_title(id)} <span class="a-hint">· {role}</span>
          </div>
        </div>
      </section>

      <section :if={@tab == "agents"} class="a-section a-agents">
        <div :if={@agents == []} class="a-panel a-empty">
          No agent has started yet. Each one appears here, and in the list on the left.
        </div>

        <div :if={@agents != []} class="a-term-tabs">
          <.link
            :for={agent <- @agents}
            patch={~p"/workflows/#{@run.id}/agents?#{[a: agent.session_id]}"}
            id={"agent-tab-#{agent.session_id}"}
            class={["a-term-tab", @agent == agent.session_id && "a-term-tab-on"]}
          >
            <span class={["a-dot", "a-status-#{agent.status}"]}></span>
            {agent.label}
            <span :if={agent.role == "implementer"} class="a-hint">· main</span>
          </.link>
        </div>

        <div :if={@agent} class="a-panel">
          <div class="a-agent-head">
            <span class="a-mono a-faint">{@agent_harness}</span>
            <.status status={@agent_session.status} />
            <span style="flex:1"></span>
            <button
              class="a-btn a-btn-sm"
              phx-click="open_agent_terminal"
              phx-value-id={@agent}
              id={"open-cli-#{@agent}"}
              title="Run the harness's own interface on this conversation"
            >
              Open in the CLI
            </button>
            <.link navigate={~p"/sessions/#{@agent}"} class="a-hint a-link">Open on its own →</.link>
          </div>

          <div id={"agent-output-#{@agent}"} class="a-activity" phx-hook="FollowTail">
            <div
              :if={@agent_events == [] and not Alkim.Session.terminal?(@agent_session.status)}
              class="a-empty"
            >
              Waiting for output…
            </div>
            <div
              :if={@agent_events == [] and Alkim.Session.terminal?(@agent_session.status)}
              class="a-empty"
            >
              This agent has finished and its process is gone. Alkim keeps a session's
              activity in memory while it runs, so there is nothing to replay here — the
              <.link patch={~p"/workflows/#{@run.id}/timeline"} class="a-link">timeline</.link>
              keeps what it said.
            </div>
            <.event
              :for={event <- @agent_events}
              id={"ae-#{@agent}-#{event.seq}"}
              event={event}
              harness_name={@agent_harness}
            />
          </div>
        </div>
      </section>

      <section :if={@tab == "changes"} class="a-section">
        <div :if={is_nil(@worktree)} class="a-panel a-empty">
          This run works in the project folder, so what it changed cannot be told apart
          from anything else happening there. Start a run in its own worktree to see that.
        </div>

        <div :if={@worktree} class="a-panel">
          <dl class="a-meta">
            <div>
              <dt>Branch</dt><dd class="a-mono">{@worktree.branch}</dd>
            </div>
            <div>
              <dt>From</dt><dd class="a-mono">{@worktree.base_branch || "detached"}</dd>
            </div>
            <div>
              <dt>Directory</dt>
              <dd class="a-mono a-truncate">{short_path(@worktree.path)}</dd>
            </div>
          </dl>
        </div>

        <.work_summary :if={@worktree} work={Worktrees.work(@worktree)} />
      </section>

      <section :if={@tab == "roles"} class="a-section">
        <div class="a-panel a-rows" id="workflow-roles">
          <div :for={{role, spec} <- sort_roles(@run.roles)} class="a-row a-row-role">
            <span>{Role.title(String.to_existing_atom(role))}</span>
            <span>
              {harness_name(spec["harness"])}
              <span :if={spec["provider"]} class="a-hint">· {spec["provider"]}</span>
            </span>
            <span class="a-mono a-muted a-truncate">{spec["model"] || "default model"}</span>
            <span class={["a-hint", spec["enforcement"] == "none" && "a-warn"]}>
              {permission_note(spec)}
            </span>
          </div>
        </div>
        <ul :if={(@run.metadata["limitations"] || []) != []} class="a-hint a-notes">
          <li :for={note <- @run.metadata["limitations"]}>{note}</li>
        </ul>
      </section>
    </Layouts.app>
    """
  end

  attr :work, :any, required: true

  defp work_summary(assigns) do
    ~H"""
    <div :if={@work == :unavailable} class="a-panel a-empty a-mt">
      The worktree is gone, so git can no longer say what changed in it.
    </div>
    <div :if={is_map(@work)} class="a-panel a-mt" style="padding:.8rem 1rem">
      <p class="a-hint">
        {@work.files} file(s) · <span class="a-change-A">+{@work.insertions}</span>
        <span class="a-change-D">−{@work.deletions}</span>
        · {@work.commits} commit(s)<span :if={@work.untracked > 0}>
          · {@work.untracked} untracked
        </span>
      </p>
    </div>
    """
  end

  attr :step, :any, required: true

  defp step_line(assigns) do
    ~H"""
    <span class={["a-step-mark", "a-step-#{@step.status}"]}>{mark(@step.status)}</span>
    <span>{step_label(@step)}</span>
    <span :if={@step.harness} class="a-hint">· {harness_name(@step.harness)}</span>
    <span :if={@step.kind == :advisor} class="a-hint">· {@step.metadata["reason"]}</span>
    <span :if={@step.iteration > 1 and @step.kind == :step} class="a-hint">· iteration {@step.iteration}</span>
    <span class="a-mono a-muted" style="margin-left:auto">
      <%= if @step.status in [:running, :waiting] do %>
        <.elapsed id={"step-elapsed-#{@step.id}"} since={@step.started_at} />
      <% else %>
        {format_duration(@step.started_at, @step.completed_at)}
      <% end %>
    </span>
    <.link :if={@step.session_id} navigate={~p"/sessions/#{@step.session_id}"} class="a-hint a-link">session →</.link>
    """
  end

  attr :run, Run, required: true
  attr :reply, :string, required: true

  defp checkpoint(%{run: %{waiting_reason: "clarification_requested"}} = assigns) do
    ~H"""
    <form class="a-composer" id="human-reply" phx-submit="reply" phx-change="reply_change">
      <span class="a-label">The implementer asks: {@run.waiting_detail}</span>
      <textarea name="reply" class="a-textarea" id="reply-input" phx-hook="SubmitOnMetaEnter">{@reply}</textarea>
      <div class="a-composer-actions">
        <span class="a-hint">Your answer is sent into the implementer's conversation.</span>
        <button type="submit" class="a-btn a-btn-primary">Send answer</button>
      </div>
    </form>
    """
  end

  defp checkpoint(assigns) do
    ~H"""
    <div class="a-composer" id="checkpoint">
      <span class="a-label">Waiting for you — {reason_label(@run.waiting_reason)}</span>
      <span class="a-hint">{@run.waiting_detail}</span>
      <div style="display:flex;gap:.5rem">
        <button
          :if={@run.waiting_reason == "max_iterations_reached"}
          class="a-btn a-btn-primary"
          phx-click="resume"
          id="resume-workflow"
        >
          Run one more iteration
        </button>
        <button
          :if={@run.waiting_reason in ["step_failed", "unparseable_audit"]}
          class="a-btn a-btn-primary"
          phx-click="resume"
          id="resume-workflow"
        >
          Retry step
        </button>
        <button class="a-btn" phx-click="complete" id="complete-workflow">Accept as done</button>
      </div>
    </div>
    """
  end

  defp sort_roles(roles),
    do:
      Enum.sort_by(roles, fn {role, _} ->
        Enum.find_index(Role.ids(), &(Atom.to_string(&1) == role))
      end)

  defp mark(:completed), do: "✓"
  defp mark(:failed), do: "✕"
  defp mark(:stopped), do: "■"
  defp mark(:waiting), do: "◐"
  defp mark(:running), do: "●"

  defp step_label(%{kind: :advisor}), do: "Advisor"
  defp step_label(%{kind: :human}), do: "You"
  defp step_label(%{step: step}), do: step_title(step)

  defp step_title(id), do: id |> String.replace("_", "-") |> String.capitalize()

  defp who(:user), do: "You"
  defp who(:alkim), do: "Alkim"
  defp who(role), do: role |> to_string() |> String.capitalize()

  defp reason_label("max_iterations_reached"), do: "max iterations reached"
  defp reason_label("step_failed"), do: "a step failed"
  defp reason_label("unparseable_audit"), do: "the auditor's verdict could not be read"
  defp reason_label("findings_unresolved"), do: "findings remain"
  defp reason_label(other), do: other

  defp permission_note(%{"write" => true, "permission_mode" => nil}),
    do: "writes · harness default permissions"

  defp permission_note(%{"write" => true, "permission_mode" => mode}), do: "writes · #{mode}"
  defp permission_note(%{"enforcement" => "sandbox"}), do: "read-only · enforced by an OS sandbox"
  defp permission_note(%{"enforcement" => "harness"}), do: "read-only · enforced by the harness"
  defp permission_note(_), do: "read-only NOT guaranteed"
end
