defmodule Khymeia.Workflow.Server do
  @moduledoc """
  One process per workflow run. It walks the definition's steps, starts a
  harness session for each role through `Khymeia.Runtime`, reacts to their
  events, consults the advisor on request and stops at human checkpoints.

  It never runs a harness itself and never talks to one directly: every
  agent is an ordinary supervised session whose *owner* is this process. The
  owner link gives two guarantees:

    * session events arrive here as messages (no subscription race);
    * if this process dies, its sessions stop themselves.

  Sessions are monitored too, so a crashing agent is seen as a failed step,
  never as a crash of the workflow. The workflow itself is `:temporary`
  (re-running it would repeat agent work); `Khymeia.Runtime.CrashMonitor`
  records it as failed if it ever crashes.

  Everything visible is persisted (`Khymeia.Workflow.Store`) before the
  matching event is published.
  """

  use GenServer, restart: :temporary

  alias Khymeia.Runtime
  alias Khymeia.Runtime.{CrashMonitor, EventBus}
  alias Khymeia.Runtime.Event, as: SessionEvent

  alias Khymeia.Workflow.{
    AuditResult,
    Definition,
    Event,
    Git,
    Prompts,
    Protocol,
    Role,
    Run,
    Step,
    Store
  }

  @max_diff_bytes 60_000

  defmodule State do
    @moduledoc false
    defstruct [
      :run,
      :definition,
      :roles,
      :baseline,
      :last_audit,
      :last_summary,
      :active,
      :consulting,
      :implementer,
      :waiting,
      session_opts: [],
      steps: %{},
      results: %{},
      monitors: %{},
      cursor: 0
    ]
  end

  def start_link(opts) do
    run = Keyword.fetch!(opts, :run)
    GenServer.start_link(__MODULE__, opts, name: via(run.id))
  end

  def via(id), do: {:via, Registry, {Khymeia.Workflow.Registry, id}}

  ## Callbacks

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    run = Keyword.fetch!(opts, :run)
    CrashMonitor.watch(self(), run.id, __MODULE__)

    state = %State{
      run: run,
      definition: Keyword.fetch!(opts, :definition),
      roles: Keyword.fetch!(opts, :roles),
      session_opts: Keyword.take(opts, [:turn_timeout])
    }

    {:ok, state, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state) do
    state =
      state
      |> update_run(status: :running, iteration: 1, started_at: now())
      |> Map.put(:baseline, Git.snapshot(state.run.workspace))
      |> emit("workflow.started", %{name: state.run.name})
      |> emit("workflow.iteration.started", %{iteration: 1})

    {:noreply, advance(state)}
  end

  @impl true
  def handle_call(:stop, _from, state) do
    if Run.terminal?(state.run),
      do: {:reply, {:error, :not_running}, state},
      else: {:reply, :ok, stop_everything(state)}
  end

  def handle_call({:resume, _params}, _from, %State{waiting: nil} = state),
    do: {:reply, {:error, :not_waiting}, state}

  def handle_call({:resume, params}, _from, state) do
    case resume(state, params) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call(:complete, _from, %State{waiting: nil} = state),
    do: {:reply, {:error, :not_waiting}, state}

  def handle_call(:complete, _from, state) do
    state = update_run(state, metadata: Map.put(state.run.metadata, "accepted_by_user", true))
    {:reply, :ok, finish(%{state | waiting: nil}, :completed)}
  end

  def handle_call({:ask, role, request}, from, state) do
    cond do
      Run.terminal?(state.run) ->
        {:reply, {:error, :not_running}, state}

      state.consulting ->
        {:reply, {:error, :busy}, state}

      Role.kind(role) != :consultant ->
        {:reply, {:error, :not_a_consultant}, state}

      true ->
        {:noreply,
         consult(state, role, request_reason(request), request.question, {:caller, from})}
    end
  end

  @impl true
  def handle_info({:session_event, %SessionEvent{session_id: id} = event}, state) do
    cond do
      state.active && state.active.session_id == id ->
        {:noreply, active_event(state, event)}

      state.consulting && state.consulting.session_id == id ->
        {:noreply, consult_event(state, event)}

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    {session_id, monitors} = Map.pop(state.monitors, ref)
    state = %{state | monitors: monitors}
    error = "agent session exited unexpectedly (#{inspect(reason, limit: 3)})"

    state =
      cond do
        is_nil(session_id) ->
          state

        state.consulting && state.consulting.session_id == session_id ->
          consult_failed(state, error)

        state.active && state.active.session_id == session_id ->
          state |> forget_implementer(session_id) |> step_failed(error)

        true ->
          forget_implementer(state, session_id)
      end

    {:noreply, state}
  end

  def handle_info({:EXIT, _from, _reason}, state), do: {:noreply, state}
  def handle_info(:exit_now, state), do: {:stop, :normal, state}

  @impl true
  def terminate(reason, state) do
    if reason in [:shutdown] or match?({:shutdown, _}, reason) do
      unless Run.terminal?(state.run) do
        stop_sessions(state)

        Store.save(%{
          state.run
          | status: :stopped,
            error: "Khymeia shut down",
            completed_at: now()
        })
      end
    end

    :ok
  end

  @doc false
  # Called by CrashMonitor when a workflow process died abnormally.
  def record_crash(id, reason) do
    error = "workflow process crashed: #{inspect(reason, limit: 5)}"

    with %Run{} = run <- Store.get_run(id), false <- Run.terminal?(run) do
      for %Step{status: status} = step <- Store.steps(id), status in [:running, :waiting] do
        Store.save(%{step | status: :failed, error: error, completed_at: now()})
      end

      Store.save(%{run | status: :failed, error: error, completed_at: now()})
    end

    EventBus.publish_workflow(Event.new(id, "workflow.failed", %{error: error}))
  end

  ## Engine

  defp advance(state) do
    steps = state.definition.steps

    next =
      steps
      |> Enum.with_index()
      |> Enum.drop(state.cursor)
      |> Enum.find(fn {step, _} -> Definition.holds?(step.when, state.results) end)

    case next do
      {step, index} -> run_step(%{state | cursor: index}, step)
      nil -> end_of_steps(state)
    end
  end

  defp end_of_steps(state) do
    repeat = state.definition.repeat
    iteration = state.run.iteration

    cond do
      repeat && Definition.holds?(repeat.while, state.results) &&
          iteration < state.run.max_iterations ->
        state
        |> emit("workflow.iteration.completed", %{iteration: iteration})
        |> update_run(iteration: iteration + 1)
        |> emit("workflow.iteration.started", %{iteration: iteration + 1})
        |> Map.put(:cursor, index_of(state, repeat.from))
        |> advance()

      repeat && Definition.holds?(repeat.while, state.results) ->
        wait(
          state,
          :max_iterations_reached,
          "#{state.run.max_iterations} iteration(s) done and the audit still has findings",
          :more_iterations
        )

      match?(%AuditResult{status: :findings}, state.last_audit) ->
        wait(state, :findings_unresolved, "the last audit reported findings", nil)

      true ->
        finish(state, :completed)
    end
  end

  defp run_step(state, %Definition.Step{} = def_step) do
    role = Map.fetch!(state.roles, def_step.role)
    kind = Role.kind(def_step.role)

    status =
      cond do
        kind == :reviewer -> :auditing
        state.last_audit != nil -> :fixing
        true -> :running
      end

    metadata =
      if kind == :reviewer,
        do: %{
          "round" =>
            Enum.count(state.steps, fn {_, s} -> s.role == "auditor" and s.kind == :step end) + 1
        },
        else: %{}

    step = new_step(state, :step, def_step.id, role, %{metadata: metadata})
    state = state |> put_step(step) |> update_run(status: status, current_step: def_step.id)

    state =
      state
      |> emit("workflow.step.started", step_data(step))
      |> then(fn s ->
        if kind == :reviewer, do: emit(s, "audit.started", step_data(step)), else: s
      end)

    active = %{
      step_id: step.id,
      def_step: def_step,
      kind: kind,
      texts: [],
      before: Git.snapshot(state.run.workspace)
    }

    launch(state, active, role, kind)
  end

  defp launch(state, active, role, :implementer) do
    ctx = context(state)

    case {state.implementer, state.last_audit} do
      {%{session_id: session_id}, %AuditResult{} = audit} ->
        # Keep the implementer's context: continue its own conversation.
        case Runtime.send_message(session_id, Prompts.fix(ctx, audit)) do
          :ok ->
            attach(state, active, session_id)

          {:error, reason} ->
            %{state | implementer: nil} |> launch(active, role, :implementer, reason)
        end

      {_, audit} ->
        prompt = if audit, do: Prompts.fix_fresh(ctx, audit), else: Prompts.implementer(ctx)
        start_session(state, active, role, prompt)
    end
  end

  defp launch(state, active, role, :reviewer) do
    changed = Git.changed(state.baseline, Git.snapshot(state.run.workspace))

    diff = diff(state.run.workspace, changed)

    ctx =
      Map.merge(context(state), %{summary: state.last_summary, changed_files: changed, diff: diff})

    start_session(state, active, role, Prompts.auditor(ctx))
  end

  defp launch(state, active, role, :consultant) do
    start_session(state, active, role, Prompts.advisor(context(state), "step", state.run.task))
  end

  # Resume failed (e.g. the session went away): start a fresh implementer.
  defp launch(state, active, role, :implementer, _reason),
    do: launch(state, active, role, :implementer)

  defp diff(_workspace, nil), do: nil

  defp diff(workspace, changed) do
    case Git.diff(workspace, changed, @max_diff_bytes) do
      {:ok, diff} -> diff
      :unavailable -> nil
    end
  end

  defp start_session(state, active, role, prompt) do
    case start_role_session(state, role, prompt, []) do
      {:ok, session} ->
        state = track(state, session)
        attach(state, active, session.id)

      {:error, reason} ->
        %{state | active: active}
        |> step_failed("could not start #{role.harness}: #{format_error(reason)}")
    end
  end

  defp attach(state, active, session_id) do
    step = state.steps[active.step_id]
    state = put_step(state, %{step | session_id: session_id})
    %{state | active: Map.put(active, :session_id, session_id)}
  end

  defp start_role_session(state, %Role{} = role, prompt, extra_opts) do
    attrs = %{
      harness: role.harness,
      workspace: state.run.workspace,
      prompt: prompt,
      model: role.model,
      permission_mode: role.permission_mode
    }

    opts =
      [
        owner: self(),
        metadata: %{"workflow_id" => state.run.id, "role" => Atom.to_string(role.id)}
      ] ++ state.session_opts ++ extra_opts

    Runtime.start_session(attrs, opts)
  end

  defp track(state, session) do
    ref = Process.monitor(session.pid)
    %{state | monitors: Map.put(state.monitors, ref, session.id)}
  end

  ## Active step events

  defp active_event(state, %SessionEvent{type: :output, data: %{kind: :assistant, text: text}}),
    do: put_in(state.active.texts, [text | state.active.texts])

  defp active_event(state, %SessionEvent{type: type}) when type in [:waiting, :completed] do
    state =
      if state.active.kind == :implementer do
        remember_implementer(state, type)
      else
        # Reviewers and consultants are one-shot: close their conversation.
        Runtime.complete_session(state.active.session_id)
        state
      end

    turn_done(state)
  end

  defp active_event(state, %SessionEvent{type: :failed, data: data}) do
    state
    |> forget_implementer(state.active.session_id)
    |> step_failed(data[:error] || "harness exited with status #{data[:exit_code]}")
  end

  defp active_event(state, %SessionEvent{type: :stopped}),
    do: state |> forget_implementer(state.active.session_id) |> step_failed("session was stopped")

  defp active_event(state, _event), do: state

  defp turn_done(%State{active: %{kind: :implementer} = active} = state) do
    text = joined(active.texts)

    case Protocol.parse_request(text) do
      {:ask_advisor, reason, question} ->
        consult(state, :advisor, reason, question, :implementer)

      {:ask_human, question} ->
        ask_human(state, question)

      :none ->
        changed = Git.changed(active.before, Git.snapshot(state.run.workspace))
        summary = summary(active.texts)

        state
        |> Map.put(:last_summary, summary)
        |> complete_step(%{summary: summary, changed_files: changed}, [:completed])
    end
  end

  defp turn_done(%State{active: %{kind: :reviewer} = active} = state) do
    audit = Protocol.parse_audit(joined(active.texts))
    step = state.steps[active.step_id]

    attrs = %{summary: summary(active.texts), audit: AuditResult.to_map(audit)}
    data = Map.merge(step_data(step), %{status: audit.status, findings: length(audit.findings)})

    case audit.status do
      :unparseable ->
        state =
          state
          |> save_step(step, Map.merge(attrs, %{status: :completed, completed_at: now()}))
          |> emit("audit.completed", data)

        %{state | active: nil}
        |> wait(
          :unparseable_audit,
          "the auditor did not return a readable verdict",
          {:retry, state.cursor}
        )

      status ->
        outcome =
          if status == :passed, do: [:completed, :passed], else: [:completed, :has_findings]

        state
        |> Map.put(:last_audit, audit)
        |> emit("audit.completed", data)
        |> then(fn s -> if status == :findings, do: emit(s, "audit.findings", data), else: s end)
        |> complete_step(attrs, outcome)
    end
  end

  defp turn_done(%State{active: active} = state),
    do: complete_step(state, %{summary: summary(active.texts)}, [:completed])

  defp complete_step(state, attrs, outcome) do
    %{step_id: step_id, def_step: def_step} = state.active
    step = state.steps[step_id]

    state
    |> save_step(step, Map.merge(attrs, %{status: :completed, completed_at: now()}))
    |> Map.update!(:results, &Map.put(&1, def_step.id, outcome))
    |> emit("workflow.step.completed", step_data(state.steps[step_id]))
    |> Map.merge(%{active: nil, cursor: state.cursor + 1})
    |> advance()
  end

  defp step_failed(state, error) do
    %{step_id: step_id, def_step: def_step} = state.active
    step = state.steps[step_id]

    state
    |> save_step(step, %{status: :failed, error: error, completed_at: now()})
    |> Map.update!(:results, &Map.put(&1, def_step.id, [:failed]))
    |> emit("workflow.step.failed", Map.put(step_data(step), :error, error))
    |> Map.put(:active, nil)
    |> wait(:step_failed, "#{def_step.id} failed: #{error}", {:retry, state.cursor})
  end

  ## Advisor consultations

  defp consult(state, role_id, reason, question, reply_to) do
    parent = state.active && state.active.step_id

    case consult_policy(state, role_id, reason) do
      :ok ->
        role = state.roles[role_id]

        step =
          new_step(state, :advisor, "advisor", role, %{
            input: question,
            parent_id: parent,
            metadata: %{"reason" => reason}
          })

        prompt = Prompts.advisor(context(state), reason, question)

        state =
          state
          |> put_step(step)
          |> update_run(advisor_calls: state.run.advisor_calls + 1)
          |> emit("advisor.started", Map.put(step_data(step), :reason, reason))

        # Ephemeral: the session process exits as soon as it has answered.
        case start_role_session(state, role, prompt, retention: 0) do
          {:ok, session} ->
            state = state |> track(session) |> put_step(%{step | session_id: session.id})

            %{
              state
              | consulting: %{
                  step_id: step.id,
                  session_id: session.id,
                  reason: reason,
                  reply_to: reply_to,
                  texts: []
                }
            }

          {:error, why} ->
            %{
              state
              | consulting: %{
                  step_id: step.id,
                  session_id: nil,
                  reason: reason,
                  reply_to: reply_to,
                  texts: []
                }
            }
            |> consult_failed("could not start the advisor: #{format_error(why)}")
        end

      {:error, why} ->
        step =
          new_step(state, :advisor, "advisor", state.roles[role_id], %{
            input: question,
            parent_id: parent,
            status: :failed,
            error: why,
            completed_at: now(),
            metadata: %{"reason" => reason}
          })

        state
        |> put_step(step)
        |> emit("advisor.failed", Map.put(step_data(step), :error, why))
        |> deliver(reply_to, {:error, why})
    end
  end

  defp consult_policy(state, role_id, reason) do
    policy = state.definition.advisor

    cond do
      not Map.has_key?(state.roles, role_id) ->
        {:error, "no #{role_id} is assigned to this workflow"}

      state.run.advisor_calls >= policy.max_calls ->
        {:error, "advisor call limit reached (#{policy.max_calls})"}

      reason not in policy.allowed_reasons ->
        {:error, "reason #{inspect(reason)} is not allowed"}

      true ->
        :ok
    end
  end

  defp consult_event(state, %SessionEvent{type: :output, data: %{kind: :assistant, text: text}}),
    do: put_in(state.consulting.texts, [text | state.consulting.texts])

  defp consult_event(state, %SessionEvent{type: type}) when type in [:waiting, :completed] do
    %{step_id: step_id, session_id: session_id, reply_to: reply_to, reason: reason} =
      state.consulting

    Runtime.complete_session(session_id)
    answer = summary(state.consulting.texts)
    step = state.steps[step_id]

    state
    |> save_step(step, %{status: :completed, summary: answer, completed_at: now()})
    |> emit("advisor.completed", step_data(step))
    |> Map.put(:consulting, nil)
    |> deliver(reply_to, {:ok, reason, answer})
  end

  defp consult_event(state, %SessionEvent{type: type, data: data})
       when type in [:failed, :stopped],
       do: consult_failed(state, data[:error] || "advisor session #{type}")

  defp consult_event(state, _event), do: state

  defp consult_failed(state, error) do
    %{step_id: step_id, reply_to: reply_to} = state.consulting
    step = state.steps[step_id]

    state
    |> save_step(step, %{status: :failed, error: error, completed_at: now()})
    |> emit("advisor.failed", Map.put(step_data(step), :error, error))
    |> Map.put(:consulting, nil)
    |> deliver(reply_to, {:error, error})
  end

  # Returns the consultation result to whoever asked.
  defp deliver(state, {:caller, from}, {:ok, _reason, answer}),
    do: tap(state, fn _ -> GenServer.reply(from, {:ok, answer}) end)

  defp deliver(state, {:caller, from}, {:error, why}),
    do: tap(state, fn _ -> GenServer.reply(from, {:error, why}) end)

  defp deliver(state, :implementer, {:ok, reason, answer}),
    do: continue_implementer(state, Prompts.advisor_answer(reason, answer))

  defp deliver(state, :implementer, {:error, why}),
    do: continue_implementer(state, Prompts.advisor_unavailable(why))

  defp continue_implementer(%State{active: %{session_id: session_id}} = state, message) do
    case Runtime.send_message(session_id, message) do
      :ok ->
        put_in(state.active.texts, [])

      {:error, reason} ->
        step_failed(state, "could not resume the implementer: #{format_error(reason)}")
    end
  end

  ## Human checkpoints

  defp ask_human(state, question) do
    human =
      new_step(state, :human, "human", nil, %{
        input: question,
        parent_id: state.active.step_id,
        status: :waiting
      })

    state
    |> put_step(human)
    |> save_step(state.steps[state.active.step_id], %{status: :waiting})
    |> emit("human.requested", %{question: question})
    |> wait(:clarification_requested, question, {:reply, human.id})
  end

  defp wait(state, reason, detail, action) do
    %{state | waiting: %{reason: reason, action: action}}
    |> update_run(
      status: :waiting,
      waiting_reason: Atom.to_string(reason),
      waiting_detail: detail
    )
    |> emit("workflow.waiting", %{reason: reason, detail: detail})
  end

  defp resume(%State{waiting: %{action: {:reply, human_id}}} = state, params) do
    case params |> Map.get(:reply, "") |> to_string() |> String.trim() do
      "" ->
        {:error, :reply_required}

      reply ->
        state =
          state
          |> save_step(state.steps[human_id], %{
            status: :completed,
            summary: reply,
            completed_at: now()
          })
          |> save_step(state.steps[state.active.step_id], %{status: :running})
          |> emit("human.answered", %{reply: reply})
          |> resumed()

        {:ok, continue_implementer(state, Prompts.human_reply(reply))}
    end
  end

  defp resume(%State{waiting: %{action: {:retry, index}}} = state, _params),
    do: {:ok, state |> resumed() |> Map.put(:cursor, index) |> advance()}

  defp resume(%State{waiting: %{action: :more_iterations}} = state, _params) do
    iteration = state.run.iteration + 1

    state =
      state
      |> resumed()
      |> update_run(max_iterations: state.run.max_iterations + 1, iteration: iteration)
      |> emit("workflow.iteration.started", %{iteration: iteration})
      |> Map.put(:cursor, index_of(state, state.definition.repeat.from))

    {:ok, advance(state)}
  end

  defp resume(_state, _params), do: {:error, :not_resumable}

  defp resumed(state) do
    %{state | waiting: nil}
    |> update_run(waiting_reason: nil, waiting_detail: nil, status: :running)
    |> emit("workflow.resumed", %{})
  end

  ## Finishing

  defp finish(state, status) do
    if state.implementer, do: Runtime.complete_session(state.implementer.session_id)

    state =
      state
      |> update_run(status: status, completed_at: now(), current_step: nil)
      |> then(fn s ->
        if status == :completed,
          do: emit(s, "workflow.iteration.completed", %{iteration: s.run.iteration}),
          else: s
      end)
      |> emit("workflow.#{status}", %{})

    send(self(), :exit_now)
    state
  end

  defp stop_everything(state) do
    stop_sessions(state)

    state =
      Enum.reduce([state.active, state.consulting], state, fn
        %{step_id: id}, acc ->
          save_step(acc, acc.steps[id], %{status: :stopped, completed_at: now()})

        nil, acc ->
          acc
      end)

    %{state | active: nil, consulting: nil, implementer: nil, waiting: nil}
    |> update_run(status: :stopped, completed_at: now())
    |> emit("workflow.stopped", %{})
    |> tap(fn _ -> send(self(), :exit_now) end)
  end

  defp stop_sessions(state) do
    [state.active, state.consulting, state.implementer]
    |> Enum.flat_map(fn
      %{session_id: id} when is_binary(id) -> [id]
      _ -> []
    end)
    |> Enum.uniq()
    |> Enum.each(&Runtime.stop_session/1)
  end

  ## Helpers

  defp remember_implementer(state, :waiting),
    do: %{state | implementer: %{session_id: state.active.session_id}}

  defp remember_implementer(state, :completed), do: %{state | implementer: nil}

  defp forget_implementer(%State{implementer: %{session_id: id}} = state, id),
    do: %{state | implementer: nil}

  defp forget_implementer(state, _id), do: state

  defp context(state) do
    resumable? = implementer_resumable?(state)

    %{
      workspace: state.run.workspace,
      task: state.run.task,
      constraints: state.run.constraints,
      round: Enum.count(state.steps, fn {_, s} -> s.role == "auditor" and s.kind == :step end),
      advisor:
        if(resumable? and Map.has_key?(state.roles, :advisor), do: state.definition.advisor),
      can_ask_human: resumable?
    }
  end

  defp implementer_resumable?(state) do
    with %Role{harness: harness} <- state.roles[:implementer],
         {:ok, adapter} <- Khymeia.Harness.fetch_adapter(harness) do
      adapter.capabilities().resume
    else
      _ -> false
    end
  end

  defp request_reason(%{reason: reason}) when not is_nil(reason), do: to_string(reason)

  defp request_reason(%{type: type}),
    do: type |> to_string() |> String.replace_suffix("_question", "")

  defp request_reason(_), do: "unspecified"

  defp new_step(state, kind, name, role, attrs) do
    struct!(
      %Step{
        id: Ecto.UUID.generate(),
        workflow_id: state.run.id,
        step: name,
        kind: kind,
        role: role && Atom.to_string(role.id),
        iteration: state.run.iteration,
        status: :running,
        harness: role && Atom.to_string(role.harness),
        model: role && role.model,
        permission_mode: role && role.permission_mode,
        started_at: now(),
        metadata: %{}
      },
      attrs
    )
  end

  defp put_step(state, %Step{} = step) do
    Store.save(step)
    %{state | steps: Map.put(state.steps, step.id, step)}
  end

  defp save_step(state, %Step{} = step, attrs), do: put_step(state, struct!(step, attrs))

  defp update_run(state, attrs) do
    run = struct!(state.run, attrs)
    Store.save(run)
    %{state | run: run}
  end

  defp emit(state, name, data) do
    EventBus.publish_workflow(Event.new(state.run.id, name, data))
    state
  end

  defp step_data(%Step{} = step),
    do: %{step_id: step.id, step: step.step, role: step.role, iteration: step.iteration}

  defp index_of(state, step_id), do: Enum.find_index(state.definition.steps, &(&1.id == step_id))

  defp joined(texts), do: texts |> Enum.reverse() |> Enum.join("\n\n")

  # The last thing the agent said, without protocol blocks.
  defp summary(texts) do
    Enum.find_value(texts, "", fn text ->
      case Protocol.strip(text) do
        "" -> nil
        stripped -> stripped
      end
    end)
  end

  defp format_error({:invalid, errors}), do: errors |> Map.values() |> Enum.join("; ")
  defp format_error(reason), do: inspect(reason)

  defp now, do: DateTime.utc_now()
end
