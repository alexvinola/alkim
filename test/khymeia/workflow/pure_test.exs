defmodule Khymeia.Workflow.PureTest do
  @moduledoc "Definitions, protocol parsing, git snapshots and the timeline — no processes."
  use ExUnit.Case, async: true

  alias Khymeia.Workflow.{AuditResult, Definition, Git, Presets, Protocol, Run, Step, Timeline}

  describe "Definition" do
    test "presets are valid and round-trip through their map form" do
      for preset <- Presets.all() do
        assert {:ok, ^preset} = preset |> Definition.to_map() |> Definition.from_map()
      end
    end

    test "accepts the YAML-like shape with simple conditions" do
      {:ok, d} =
        Definition.from_map(%{
          "name" => "custom",
          "steps" => [
            %{"id" => "implement", "role" => "implementer"},
            %{"id" => "audit", "role" => "auditor", "when" => "implement.completed"}
          ],
          "max_iterations" => 2
        })

      assert [_, %{when: {"implement", :completed}}] = d.steps
      assert Definition.holds?({"implement", :completed}, %{"implement" => [:completed]})
      refute Definition.holds?({"audit", :has_findings}, %{"audit" => [:completed, :passed]})
    end

    test "rejects anything beyond simple explicit conditions" do
      step = fn attrs -> Map.merge(%{"id" => "a", "role" => "implementer"}, attrs) end

      assert {:error, "unsupported condition" <> _} =
               Definition.from_map(%{"steps" => [step.(%{"when" => "a.completed and b.failed"})]})

      assert {:error, "unknown role" <> _} =
               Definition.from_map(%{"steps" => [step.(%{"role" => "wizard"})]})

      assert {:error, "unknown step zzz" <> _} =
               Definition.from_map(%{"steps" => [step.(%{"when" => "zzz.completed"})]})

      assert {:error, "step ids must be unique"} =
               Definition.from_map(%{"steps" => [step.(%{}), step.(%{})]})

      assert {:error, _} = Definition.from_map(%{"steps" => []})
    end
  end

  describe "Protocol" do
    test "finds advisor and human requests, last one wins" do
      assert {:ask_advisor, "security", "Is this safe?"} =
               Protocol.parse_request(
                 ~s(ok <khymeia:ask-advisor reason="security">Is this safe?</khymeia:ask-advisor>)
               )

      assert {:ask_advisor, "unspecified", "Q"} =
               Protocol.parse_request("<khymeia:ask-advisor>Q</khymeia:ask-advisor>")

      assert {:ask_human, "Public?"} =
               Protocol.parse_request(
                 "<khymeia:ask-advisor>old</khymeia:ask-advisor> then <khymeia:ask-human>Public?</khymeia:ask-human>"
               )

      assert :none = Protocol.parse_request("All done, tests pass.")
    end

    test "parses audit verdicts, tolerating code fences" do
      text = """
      Review done.
      <khymeia:audit>
      ```json
      {"status": "findings", "findings": [{"severity": "CRITICAL", "title": "SQL injection", "file": "a.ex", "line": 3}]}
      ```
      </khymeia:audit>
      """

      assert %AuditResult{status: :findings, findings: [f]} = Protocol.parse_audit(text)
      assert f.severity == :critical and f.file == "a.ex" and f.line == 3

      assert %AuditResult{status: :passed} =
               Protocol.parse_audit(
                 ~s(<khymeia:audit>{"status":"passed","findings":[]}</khymeia:audit>)
               )

      # "findings" without any finding is a pass; unknown severities become medium.
      assert %AuditResult{status: :passed} =
               Protocol.parse_audit(
                 ~s(<khymeia:audit>{"status":"findings","findings":[]}</khymeia:audit>)
               )

      assert %AuditResult{findings: [%{severity: :medium}]} =
               Protocol.parse_audit(
                 ~s(<khymeia:audit>{"status":"findings","findings":[{"severity":"meh","title":"x"}]}</khymeia:audit>)
               )
    end

    test "never guesses a verdict" do
      assert %AuditResult{status: :unparseable} = Protocol.parse_audit("Looks fine to me!")

      assert %AuditResult{status: :unparseable} =
               Protocol.parse_audit("<khymeia:audit>not json</khymeia:audit>")

      assert %AuditResult{status: :unparseable} =
               Protocol.parse_audit(~s(<khymeia:audit>{"status":"maybe"}</khymeia:audit>))
    end

    test "strips protocol blocks from text shown to people" do
      assert Protocol.strip(~s(Done. <khymeia:audit>{"status":"passed"}</khymeia:audit>)) ==
               "Done."
    end
  end

  describe "Git" do
    @describetag :tmp_dir

    test "snapshots report exactly what changed between two points", %{tmp_dir: dir} do
      git = System.find_executable("git") || flunk("git is required for this test")
      run = fn args -> {_, 0} = System.cmd(git, ["-C", dir | args], stderr_to_stdout: true) end

      run.(["init", "-q"])
      File.write!(Path.join(dir, "a.txt"), "one")
      File.write!(Path.join(dir, "dirty.txt"), "before")
      run.(["add", "."])
      run.(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"])
      # Already dirty before the "step" starts:
      File.write!(Path.join(dir, "dirty.txt"), "dirty")

      before = Git.snapshot(dir)
      File.write!(Path.join(dir, "a.txt"), "two")
      File.write!(Path.join(dir, "new.txt"), "new")
      after_ = Git.snapshot(dir)

      assert Git.changed(before, after_) == ["a.txt", "new.txt"]
      assert {:ok, diff} = Git.diff(dir, ["a.txt"], 10_000)
      assert diff =~ "-one" and diff =~ "+two"

      # Touching an already-dirty file again is detected too.
      File.write!(Path.join(dir, "dirty.txt"), "dirtier")
      assert "dirty.txt" in Git.changed(after_, Git.snapshot(dir))
    end

    test "paths are relative to a workspace inside a larger repository", %{tmp_dir: dir} do
      git = System.find_executable("git") || flunk("git is required for this test")
      {_, 0} = System.cmd(git, ["-C", dir, "init", "-q"])
      File.mkdir_p!(Path.join(dir, "apps/web"))
      File.write!(Path.join(dir, "outside.txt"), "x")
      ws = Path.join(dir, "apps/web")

      before = Git.snapshot(ws)
      File.write!(Path.join(ws, "page.ex"), "new")
      assert Git.changed(before, Git.snapshot(ws)) == ["page.ex"]
    end

    test "outside a repository nothing is invented" do
      # (@tmp_dir lives inside this project's own repository.)
      dir = Path.join(System.tmp_dir!(), "khymeia-nogit-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      assert Git.snapshot(dir) == :unavailable
      assert Git.changed(:unavailable, :unavailable) == nil
    end
  end

  describe "Timeline" do
    test "projects steps into a conversation, in order" do
      t = fn s -> DateTime.add(~U[2026-01-01 10:00:00Z], s) end

      run = %Run{
        id: "r",
        task: "Add OAuth",
        status: :completed,
        started_at: t.(0),
        completed_at: t.(50)
      }

      steps = [
        %Step{
          id: "1",
          step: "implement",
          kind: :step,
          role: "implementer",
          harness: "claude",
          status: :completed,
          started_at: t.(1),
          completed_at: t.(20),
          summary: "Implemented.",
          changed_files: ["lib/a.ex"]
        },
        %Step{
          id: "2",
          step: "advisor",
          kind: :advisor,
          role: "advisor",
          status: :completed,
          input: "ETS?",
          metadata: %{"reason" => "architecture"},
          started_at: t.(5),
          completed_at: t.(8),
          summary: "Use ETS."
        },
        %Step{
          id: "3",
          step: "audit",
          kind: :step,
          role: "auditor",
          harness: "codex",
          iteration: 1,
          status: :completed,
          started_at: t.(21),
          completed_at: t.(30),
          audit: %{
            "status" => "findings",
            "findings" => [%{"severity" => "high", "title" => "Bug"}]
          }
        }
      ]

      entries = Timeline.build(run, steps)

      assert Enum.map(entries, & &1.who) ==
               [
                 :user,
                 :implementer,
                 :implementer,
                 :advisor,
                 :implementer,
                 :auditor,
                 :auditor,
                 :khymeia
               ]

      assert Enum.at(entries, 3).text == "Use ETS."
      assert Enum.at(entries, 4).text =~ "Changed: lib/a.ex"
      assert Enum.at(entries, 6).text =~ "Found 1 issue(s)"
    end
  end
end
