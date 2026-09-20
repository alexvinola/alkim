defmodule KhymeiaWeb.WorkflowLive do
  @moduledoc """
  A workflow run: role assignments, the step tree (with nested advisor
  consultations), human checkpoints and the unified timeline.

  Workflow events only say *that* something changed; the view re-reads the
  persisted run, which is the source of truth. No polling.
  """

  use KhymeiaWeb, :live_view

  import KhymeiaWeb.SessionComponents

  alias Khymeia.Workflow
  alias Khymeia.Workflow.{Role, Run, Timeline}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: Workflow.subscribe(id)

    case Workflow.get(id) do
      {:ok, run, steps} ->
        {:ok,
         socket
         |> assign(reply: "", project: Khymeia.Projects.get(run.project_id))
         |> assign_run(run, steps)}

      :error ->
        {:ok, socket |> put_flash(:error, "Workflow not found") |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_info({:workflow_event, _event}, socket), do: {:noreply, reload(socket)}

  @impl true
  def handle_event("stop", _, socket), do: act(socket, Workflow.stop(socket.assigns.run.id))
  def handle_event("resume", _, socket), do: act(socket, Workflow.resume(socket.assigns.run.id))

  def handle_event("complete", _, socket),
    do: act(socket, Workflow.complete(socket.assigns.run.id))

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
      {:ok, run, steps} -> assign_run(socket, run, steps)
      :error -> socket
    end
  end

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
      page_title: "#{title(run)} · Khymeia",
      run: run,
      top: top,
      children: children,
      pending: pending,
      timeline: Timeline.build(run, steps),
      live: Workflow.alive?(run.id)
    )
  end

  defp title(run),
    do: run.task |> String.split("\n", trim: true) |> List.first("") |> String.slice(0, 70)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} nav={@nav} active={:sessions} project={@project}>
      <div class="k-section-head">
        <div style="min-width:0">
          <span class="k-h2">Workflow · {@run.title || @run.name}</span>
          <h1 class="k-h1 k-truncate">{title(@run)}</h1>
        </div>
        <div style="display:flex;gap:.5rem;flex:none">
          <button
            :if={@live and Run.active?(@run)}
            class="k-btn k-btn-danger"
            phx-click="stop"
            id="stop-workflow"
            data-confirm="Stop this workflow and every agent it started?"
          >
            Stop
          </button>
        </div>
      </div>

      <section class="k-section">
        <div class="k-panel">
          <dl class="k-meta" id="workflow-meta">
            <div>
              <dt>Status</dt><dd id="workflow-status"><.status status={@run.status} /></dd>
            </div>
            <div>
              <dt>Iteration</dt><dd>{@run.iteration} / {@run.max_iterations}</dd>
            </div>
            <div>
              <dt>Workspace</dt><dd class="k-mono">{short_path(@run.workspace)}</dd>
            </div>
            <div>
              <dt>Started</dt><dd>{datetime(@run.started_at)}</dd>
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
          <div :if={@run.error} class="k-banner k-banner-error" style="margin:0 1rem 1rem">
            {@run.error}
          </div>
          <.checkpoint :if={@run.status == :waiting and @live} run={@run} reply={@reply} />
          <div :if={@run.status == :waiting and not @live} class="k-banner" style="margin:0 1rem 1rem">
            Waiting, but the workflow process is gone; it cannot be resumed.
          </div>
        </div>
      </section>

      <section class="k-section">
        <div class="k-section-head">
          <h2 class="k-h2">Roles</h2>
        </div>
        <div class="k-panel k-rows" id="workflow-roles">
          <div :for={{role, spec} <- sort_roles(@run.roles)} class="k-row k-row-role">
            <span>{Role.title(String.to_existing_atom(role))}</span>
            <span>
              {harness_name(spec["harness"])}
              <span :if={spec["provider"]} class="k-hint">· {spec["provider"]}</span>
            </span>
            <span class="k-mono k-muted k-truncate">{spec["model"] || "default model"}</span>
            <span class={["k-hint", spec["enforcement"] == "none" && "k-warn"]}>{permission_note(spec)}</span>
          </div>
        </div>
        <ul :if={(@run.metadata["limitations"] || []) != []} class="k-hint k-notes">
          <li :for={note <- @run.metadata["limitations"]}>{note}</li>
        </ul>
      </section>

      <section class="k-section">
        <div class="k-section-head">
          <h2 class="k-h2">Steps</h2>
        </div>
        <div class="k-panel k-tree" id="workflow-steps">
          <div :for={step <- @top} class="k-tree-item" id={"step-#{step.id}"}>
            <div class="k-step-line"><.step_line step={step} /></div>
            <div
              :for={child <- Map.get(@children, step.id, [])}
              class="k-tree-child k-step-line"
              id={"step-#{child.id}"}
            >
              <span class="k-faint">└─</span> <.step_line step={child} />
            </div>
          </div>
          <div
            :for={{id, role} <- @pending}
            class="k-tree-item k-step-line k-faint"
            id={"pending-#{id}"}
          >
            <span class="k-step-mark">○</span> {step_title(id)} <span class="k-hint">· {role}</span>
          </div>
        </div>
      </section>

      <section class="k-section">
        <div class="k-section-head">
          <h2 class="k-h2">Timeline</h2>
        </div>
        <div class="k-panel k-activity" id="workflow-timeline" phx-hook="FollowTail">
          <div
            :for={e <- @timeline}
            id={"tl-#{e.id}"}
            class={["k-ev k-msg", "k-who-#{e.who}", "k-tone-#{e.tone}"]}
          >
            <span class="k-ev-time">{time(e.at)}</span>
            <div class="k-ev-body"><span class="k-who">{who(e.who)}</span>{e.text}</div>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :step, :any, required: true

  defp step_line(assigns) do
    ~H"""
    <span class={["k-step-mark", "k-step-#{@step.status}"]}>{mark(@step.status)}</span>
    <span>{step_label(@step)}</span>
    <span :if={@step.harness} class="k-hint">· {harness_name(@step.harness)}</span>
    <span :if={@step.kind == :advisor} class="k-hint">· {@step.metadata["reason"]}</span>
    <span :if={@step.iteration > 1 and @step.kind == :step} class="k-hint">· iteration {@step.iteration}</span>
    <span class="k-mono k-muted" style="margin-left:auto">
      <%= if @step.status in [:running, :waiting] do %>
        <.elapsed id={"step-elapsed-#{@step.id}"} since={@step.started_at} />
      <% else %>
        {format_duration(@step.started_at, @step.completed_at)}
      <% end %>
    </span>
    <.link :if={@step.session_id} navigate={~p"/sessions/#{@step.session_id}"} class="k-hint k-link">session →</.link>
    """
  end

  attr :run, Run, required: true
  attr :reply, :string, required: true

  defp checkpoint(%{run: %{waiting_reason: "clarification_requested"}} = assigns) do
    ~H"""
    <form class="k-composer" id="human-reply" phx-submit="reply" phx-change="reply_change">
      <span class="k-label">The implementer asks: {@run.waiting_detail}</span>
      <textarea name="reply" class="k-textarea" id="reply-input" phx-hook="SubmitOnMetaEnter">{@reply}</textarea>
      <div class="k-composer-actions">
        <span class="k-hint">Your answer is sent into the implementer's conversation.</span>
        <button type="submit" class="k-btn k-btn-primary">Send answer</button>
      </div>
    </form>
    """
  end

  defp checkpoint(assigns) do
    ~H"""
    <div class="k-composer" id="checkpoint">
      <span class="k-label">Waiting for you — {reason_label(@run.waiting_reason)}</span>
      <span class="k-hint">{@run.waiting_detail}</span>
      <div style="display:flex;gap:.5rem">
        <button
          :if={@run.waiting_reason == "max_iterations_reached"}
          class="k-btn k-btn-primary"
          phx-click="resume"
          id="resume-workflow"
        >
          Run one more iteration
        </button>
        <button
          :if={@run.waiting_reason in ["step_failed", "unparseable_audit"]}
          class="k-btn k-btn-primary"
          phx-click="resume"
          id="resume-workflow"
        >
          Retry step
        </button>
        <button class="k-btn" phx-click="complete" id="complete-workflow">Accept as done</button>
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
  defp who(:khymeia), do: "Khymeia"
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
