defmodule Khymeia.WorkflowTest do
  use Khymeia.RuntimeCase, async: false

  alias Khymeia.Workflow
  alias Khymeia.Workflow.{Run, Store}

  @moduletag :capture_log

  describe "coding with audit" do
    test "implement → audit → pass completes the workflow", %{workspace: ws} do
      run = start_workflow!(ws, %{implementer: "success", auditor: "audit-pass", advisor: nil})
      events = await_workflow(run.id, "workflow.completed")

      names = Enum.map(events, & &1.name)

      assert names --
               [
                 "workflow.started",
                 "workflow.step.started",
                 "audit.started",
                 "audit.completed",
                 "workflow.step.completed",
                 "workflow.completed"
               ] ==
               [
                 "workflow.iteration.started",
                 "workflow.step.started",
                 "workflow.step.completed",
                 "workflow.iteration.completed"
               ]

      assert {:ok, %Run{status: :completed, iteration: 1}, steps} = Workflow.get(run.id)

      assert [
               %{step: "implement", status: :completed} = impl,
               %{step: "audit", status: :completed} = audit
             ] = steps

      assert impl.summary =~ "Done."
      assert audit.audit["status"] == "passed"
      refute Enum.any?(steps, &(&1.step in ["fix", "re_audit"]))

      # One-shot auditor and finished implementer: no agent is left running.
      eventually(fn ->
        Khymeia.Runtime.list_live() |> Enum.all?(&Khymeia.Session.terminal?(&1.status))
      end)
    end

    test "findings → fix (same implementer conversation) → re-audit → pass", %{workspace: ws} do
      run =
        start_workflow!(ws, %{implementer: "success", auditor: "audit-fix-once", advisor: nil})

      events = await_workflow(run.id, "workflow.completed")

      assert Enum.any?(events, &(&1.name == "audit.findings" and &1.data.findings == 2))

      steps = steps(run.id)
      assert Enum.map(steps, & &1.step) == ~w(implement audit fix re_audit)

      [implement, audit, fix, re_audit] = steps
      assert audit.audit["status"] == "findings"

      assert [%{"severity" => "high", "title" => "Missing input validation"} | _] =
               audit.audit["findings"]

      assert re_audit.audit["status"] == "passed"
      assert {audit.metadata["round"], re_audit.metadata["round"]} == {1, 2}

      # The fix resumed the implementer's own conversation...
      assert fix.session_id == implement.session_id
      assert fix.summary =~ "the independent auditor reviewed your work (audit round 1)"
      # ...while each audit was an independent session.
      refute re_audit.session_id == audit.session_id
    end

    test "max iterations stops the loop and waits for a human", %{workspace: ws} do
      run =
        start_workflow!(ws, %{implementer: "success", auditor: "audit-findings", advisor: nil}, %{
          max_iterations: 2
        })

      await_workflow(run.id, "workflow.waiting")

      assert {:ok, %Run{status: :waiting, waiting_reason: "max_iterations_reached", iteration: 2},
              steps} =
               Workflow.get(run.id)

      assert Enum.count(steps, &(&1.role == "auditor")) == 3

      # A human can grant one more iteration...
      assert :ok = Workflow.resume(run.id)
      await_workflow(run.id, "workflow.waiting")
      assert Enum.count(steps(run.id), &(&1.role == "auditor")) == 4

      # ...or accept the result.
      assert :ok = Workflow.complete(run.id)
      await_workflow(run.id, "workflow.completed")

      assert %Run{status: :completed, metadata: %{"accepted_by_user" => true}} =
               Store.get_run(run.id)
    end
  end

  describe "advisor consultations" do
    test "an implementer can consult the advisor through Khymeia", %{workspace: ws} do
      run =
        start_workflow!(ws, %{implementer: "ask-advisor", advisor: "advise"}, %{
          workflow: "simple-coding"
        })

      events = await_workflow(run.id, "workflow.completed")

      assert Enum.any?(
               events,
               &(&1.name == "advisor.started" and &1.data.reason == "architecture")
             )

      assert Enum.any?(events, &(&1.name == "advisor.completed"))

      [implement, advisor] = steps(run.id)
      assert advisor.kind == :advisor
      assert advisor.parent_id == implement.id
      assert advisor.input == "Should the cache be a GenServer or ETS?"
      assert advisor.summary == "Recommendation: use ETS owned by a GenServer."

      # The answer went back into the implementer's conversation.
      assert implement.status == :completed
      assert implement.summary =~ "answer from the advisor"

      # The advisor was ephemeral: its session process is gone.
      eventually(fn -> Khymeia.Runtime.Registry.lookup(advisor.session_id) == :error end)
      assert Store.get_run(run.id).advisor_calls == 1
    end

    test "a failing advisor does not fail the workflow", %{workspace: ws} do
      run =
        start_workflow!(ws, %{implementer: "ask-advisor", advisor: "failure"}, %{
          workflow: "simple-coding"
        })

      events = await_workflow(run.id, "workflow.completed")

      assert Enum.any?(events, &(&1.name == "advisor.failed"))
      [implement, advisor] = steps(run.id)
      assert advisor.status == :failed
      assert implement.status == :completed
      assert implement.summary =~ "could not be consulted"
    end

    test "a crashing advisor session does not crash the workflow", %{workspace: ws} do
      run =
        start_workflow!(ws, %{implementer: "ask-advisor", advisor: "hang"}, %{
          workflow: "simple-coding"
        })

      await_workflow(run.id, "advisor.started")

      advisor = eventually_step(run.id, &(&1.kind == :advisor and &1.session_id))
      Process.exit(session_pid(advisor), :kill)

      await_workflow(run.id, "workflow.completed")
      assert %{status: :failed} = Enum.find(steps(run.id), &(&1.kind == :advisor))
    end

    test "the escalation policy is deterministic", %{workspace: ws} do
      run =
        start_workflow!(ws, %{implementer: "hang", advisor: "advise"}, %{
          workflow: "simple-coding"
        })

      await_workflow(run.id, "workflow.step.started")

      assert {:ok, "Recommendation: use ETS owned by a GenServer."} =
               Workflow.ask(run.id, :advisor, %{
                 type: :architecture_question,
                 question: "GenServer or ETS?"
               })

      assert {:error, "reason \"vibes\" is not allowed"} =
               Workflow.ask(run.id, :advisor, %{reason: "vibes", question: "?"})

      assert {:error, :not_a_consultant} = Workflow.ask(run.id, :auditor, %{question: "?"})
      assert {:error, "unknown role" <> _} = Workflow.ask(run.id, :poet, %{question: "?"})
      Workflow.stop(run.id)
    end
  end

  describe "failures stay contained" do
    test "an auditor crash leaves the workflow waiting, and the runtime up", %{workspace: ws} do
      run = start_workflow!(ws, %{implementer: "success", auditor: "hang", advisor: nil})
      await_workflow(run.id, "audit.started")

      audit = eventually_step(run.id, &(&1.step == "audit" and &1.session_id))
      Process.exit(session_pid(audit), :kill)

      await_workflow(run.id, "workflow.waiting")
      assert %Run{status: :waiting, waiting_reason: "step_failed"} = Store.get_run(run.id)
      assert Workflow.alive?(run.id)
      assert Process.whereis(Khymeia.Workflow.Supervisor)
      assert Process.whereis(Khymeia.Runtime.SessionSupervisor)

      Workflow.stop(run.id)
      await_workflow(run.id, "workflow.stopped")
    end

    test "a failed implementer can be retried by a human", %{workspace: ws} do
      run =
        start_workflow!(ws, %{implementer: "failure", advisor: nil}, %{workflow: "simple-coding"})

      await_workflow(run.id, "workflow.waiting")

      assert %{waiting_reason: "step_failed", waiting_detail: "implement failed: " <> _} =
               Store.get_run(run.id)

      assert :ok = Workflow.resume(run.id)
      await_workflow(run.id, "workflow.waiting")
      assert Enum.count(steps(run.id), &(&1.step == "implement" and &1.status == :failed)) == 2
    end

    test "a step that exceeds its timeout fails", %{workspace: ws} do
      run =
        start_workflow!(ws, %{implementer: "hang", advisor: nil}, %{workflow: "simple-coding"},
          turn_timeout: 300
        )

      await_workflow(run.id, "workflow.step.failed")
      assert [%{status: :failed, error: "timed out" <> _}] = steps(run.id)
    end

    test "a crashed workflow is recorded and its agents stop", %{workspace: ws} do
      run =
        start_workflow!(ws, %{implementer: "hang", advisor: nil}, %{workflow: "simple-coding"})

      await_workflow(run.id, "workflow.step.started")
      step = eventually_step(run.id, & &1.session_id)
      agent = session_pid(step)

      [{pid, _}] = Registry.lookup(Khymeia.Workflow.Registry, run.id)
      Process.exit(pid, :kill)

      await_workflow(run.id, "workflow.failed")
      assert %Run{status: :failed, error: "workflow process crashed" <> _} = Store.get_run(run.id)
      assert [%{status: :failed}] = steps(run.id)

      eventually(fn ->
        not Process.alive?(agent) or
          Khymeia.Runtime.get_session(step.session_id) |> elem(1) |> Map.get(:status) == :stopped
      end)
    end

    test "two workflows run concurrently without sharing state", %{workspace: ws} do
      other = workspace!()
      a = start_workflow!(ws, %{implementer: "success", auditor: "audit-pass", advisor: nil})

      b =
        start_workflow!(other, %{implementer: "success", auditor: "audit-fix-once", advisor: nil})

      await_workflow(a.id, "workflow.completed")
      await_workflow(b.id, "workflow.completed")

      assert Enum.map(steps(a.id), & &1.step) == ~w(implement audit)
      assert Enum.map(steps(b.id), & &1.step) == ~w(implement audit fix re_audit)

      assert MapSet.disjoint?(
               MapSet.new(steps(a.id), & &1.session_id),
               MapSet.new(steps(b.id), & &1.session_id)
             )

      assert Store.get_run(a.id).workspace != Store.get_run(b.id).workspace
    end
  end

  describe "human checkpoints" do
    test "an implementer can ask the user and continue with the answer", %{workspace: ws} do
      run =
        start_workflow!(ws, %{implementer: "ask-human", advisor: nil}, %{
          workflow: "simple-coding"
        })

      await_workflow(run.id, "workflow.waiting")

      assert %{
               waiting_reason: "clarification_requested",
               waiting_detail: "Should the new endpoint be public?"
             } =
               Store.get_run(run.id)

      assert {:error, :reply_required} = Workflow.resume(run.id, %{reply: " "})
      assert :ok = Workflow.resume(run.id, %{"reply" => "No, keep it internal."})
      await_workflow(run.id, "workflow.completed")

      assert [
               %{step: "implement", summary: summary},
               %{kind: :human, summary: "No, keep it internal."}
             ] = steps(run.id)

      assert summary =~ "answer from the user"
    end
  end

  describe "validation and persistence" do
    test "invalid requests start nothing", %{workspace: ws} do
      assert {:error, {:invalid, errors}} =
               Workflow.start(%{
                 workspace: "/etc",
                 task: " ",
                 roles: %{implementer: %{harness: "claude"}}
               })

      assert Map.has_key?(errors, :workspace)

      assert {:error, {:invalid, %{task: _}}} = Workflow.start(%{workspace: ws, task: ""})

      assert {:error, {:invalid, %{role_implementer: _}}} =
               Workflow.start(%{
                 workspace: ws,
                 task: "x",
                 roles: %{implementer: %{harness: "fake", model: "nope"}}
               })

      assert {:error, {:invalid, %{max_iterations: _}}} =
               Workflow.start(%{workspace: ws, task: "x", max_iterations: 99})
    end

    test "roles record how read-only is (not) enforced", %{workspace: ws} do
      run = start_workflow!(ws, %{implementer: "success", auditor: "audit-pass", advisor: nil})
      await_workflow(run.id, "workflow.completed")

      run = Store.get_run(run.id)
      assert run.roles["auditor"]["write"] == false
      assert run.roles["auditor"]["enforcement"] == "none"
      assert Enum.any?(run.metadata["limitations"], &(&1 =~ "cannot guarantee"))
    end

    test "runs left active by a previous process are marked interrupted", %{workspace: ws} do
      run =
        start_workflow!(ws, %{implementer: "hang", advisor: nil}, %{workflow: "simple-coding"})

      await_workflow(run.id, "workflow.step.started")
      eventually_step(run.id, & &1.session_id)

      # Simulate a restart: the process is gone without recording anything.
      [{pid, _}] = Registry.lookup(Khymeia.Workflow.Registry, run.id)
      :sys.suspend(pid)
      Store.fail_interrupted()

      assert %Run{status: :failed, error: "interrupted" <> _} = Store.get_run(run.id)
      assert [%{status: :failed, error: "interrupted"}] = steps(run.id)
      :sys.resume(pid)
    end
  end

  defp eventually_step(run_id, fun) do
    eventually(fn -> Enum.find(steps(run_id), fun) end)
    Enum.find(steps(run_id), fun)
  end
end
