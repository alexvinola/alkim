defmodule Alkim.Workflow.Timeline do
  @moduledoc """
  The conversation-like view of a run (USER / IMPLEMENTER / ADVISOR /
  AUDITOR / ALKIM), projected from the persisted run and steps.

  It replaces nothing: each agent still runs in its own session with its own
  activity log. Because it is derived from stored steps only, it looks the
  same live, after the process has finished, and after a restart.
  """

  alias Alkim.Workflow.{AuditResult, Prompts, Run, Step}

  @type entry :: %{
          id: String.t(),
          who: :user | :implementer | :advisor | :auditor | :alkim | atom(),
          at: DateTime.t() | nil,
          text: String.t(),
          tone: :normal | :muted | :good | :bad
        }

  @spec build(Run.t(), [Step.t()]) :: [entry()]
  def build(%Run{} = run, steps) do
    task = [
      %{
        id: "task",
        who: :user,
        at: run.started_at || run.inserted_at,
        text: run.task,
        tone: :normal
      }
    ]

    (task ++ Enum.flat_map(steps, &entries/1) ++ closing(run))
    |> Enum.with_index()
    |> Enum.sort_by(fn {e, i} -> {e.at && DateTime.to_unix(e.at, :microsecond), i} end)
    |> Enum.map(&elem(&1, 0))
  end

  defp entries(%Step{kind: :advisor} = s) do
    reason = s.metadata["reason"]

    [
      entry(
        s,
        "ask",
        :implementer,
        s.started_at,
        "Asked the advisor (#{reason}): #{s.input}",
        :muted
      )
    ] ++
      case s.status do
        :completed ->
          [entry(s, "answer", :advisor, s.completed_at, s.summary, :normal)]

        :failed ->
          [entry(s, "answer", :alkim, s.completed_at, "Advisor unavailable: #{s.error}", :bad)]

        _ ->
          []
      end
  end

  defp entries(%Step{kind: :human} = s) do
    [entry(s, "ask", :implementer, s.started_at, "Needs your input: #{s.input}", :muted)] ++
      if(s.status == :completed,
        do: [entry(s, "reply", :user, s.completed_at, s.summary, :normal)],
        else: []
      )
  end

  defp entries(%Step{role: "auditor"} = s) do
    start =
      entry(
        s,
        "start",
        :auditor,
        s.started_at,
        "Auditing (round #{s.metadata["round"] || s.iteration}, #{s.harness})",
        :muted
      )

    finish =
      case {s.status, Step.audit_result(s)} do
        {:completed, %AuditResult{status: :passed}} ->
          [entry(s, "end", :auditor, s.completed_at, "Passed. " <> (s.summary || ""), :good)]

        {:completed, %AuditResult{status: :findings, findings: findings}} ->
          text = "Found #{length(findings)} issue(s):\n" <> Prompts.format_findings(findings)
          [entry(s, "end", :auditor, s.completed_at, text, :bad)]

        {:completed, _} ->
          [
            entry(
              s,
              "end",
              :auditor,
              s.completed_at,
              "No readable verdict: " <> (s.summary || ""),
              :bad
            )
          ]

        {status, _} ->
          failure(s, status)
      end

    [start | finish]
  end

  defp entries(%Step{} = s) do
    who = if s.role, do: String.to_existing_atom(s.role), else: :alkim
    verb = if s.step == "implement", do: "Started", else: "Fixing findings"

    [entry(s, "start", who, s.started_at, "#{verb} (#{s.harness})", :muted)] ++
      case s.status do
        :completed -> [entry(s, "end", who, s.completed_at, completed_text(s), :normal)]
        status -> failure(s, status)
      end
  end

  defp completed_text(%Step{summary: summary, changed_files: files}) do
    changed =
      case files do
        nil -> ""
        [] -> "\n(no file changes detected)"
        files -> "\nChanged: " <> Enum.join(files, ", ")
      end

    (summary || "Done.") <> changed
  end

  defp failure(s, :failed),
    do: [entry(s, "end", :alkim, s.completed_at, "#{s.step} failed: #{s.error}", :bad)]

  defp failure(s, :stopped),
    do: [entry(s, "end", :alkim, s.completed_at, "#{s.step} stopped", :muted)]

  defp failure(_s, _running), do: []

  defp closing(%Run{status: :waiting} = run),
    do: [
      %{
        id: "closing",
        who: :alkim,
        at: run.updated_at,
        text: "Waiting for you — #{run.waiting_detail}",
        tone: :bad
      }
    ]

  defp closing(%Run{status: :completed} = run),
    do: [
      %{
        id: "closing",
        who: :alkim,
        at: run.completed_at,
        text: "Workflow completed.",
        tone: :good
      }
    ]

  defp closing(%Run{status: status} = run) when status in [:failed, :stopped],
    do: [
      %{
        id: "closing",
        who: :alkim,
        at: run.completed_at,
        text: "Workflow #{status}. #{run.error}",
        tone: :bad
      }
    ]

  defp closing(_), do: []

  defp entry(step, suffix, who, at, text, tone),
    do: %{id: "#{step.id}-#{suffix}", who: who, at: at, text: text || "", tone: tone}
end
