defmodule Alkim.Workflow.Prompts do
  @moduledoc """
  The text each role receives. Kept in one place so the contract between
  Alkim and the harnesses (the tagged blocks of `Alkim.Workflow.Protocol`)
  is easy to audit and change.

  Messages sent into an *ongoing* conversation (fixes, advisor answers,
  human replies) never repeat the protocol tags, so an agent echoing them
  cannot trigger a request by accident.
  """

  alias Alkim.Workflow.{AuditResult, Finding}

  @doc "First turn of the implementer."
  def implementer(ctx) do
    """
    You are the IMPLEMENTER in a Alkim workflow. Another agent will
    independently audit your work afterwards.

    Workspace: #{ctx.workspace}

    ## Task
    #{ctx.task}
    #{constraints(ctx)}
    Work directly in the workspace: read, edit, run commands and tests as your
    permissions allow. When you are done, reply with a short summary of what you
    changed and how you verified it (which tests you ran and their result).
    #{advisor_instructions(ctx)}
    If the requirement is ambiguous and only the user can decide, end your reply with
    <alkim:ask-human>your question</alkim:ask-human>
    and stop; the user's answer will be sent back to you.
    """
  end

  @doc "Fix request sent into the implementer's conversation."
  def fix(ctx, %AuditResult{} = audit) do
    """
    Alkim: the independent auditor reviewed your work (audit round #{ctx.round}) and reported:

    #{format_findings(audit.findings)}

    Fix these issues in the workspace, then reply with a summary of the fixes and how you verified them.
    """
  end

  @doc "Fix request for an implementer that cannot resume its conversation."
  def fix_fresh(ctx, audit), do: implementer(ctx) <> "\n" <> fix(ctx, audit)

  def advisor_answer(reason, answer) do
    """
    Alkim: answer from the advisor (#{reason}):

    #{answer}

    Continue with the task. When you are done, reply with your summary.
    """
  end

  def advisor_unavailable(why) do
    """
    Alkim: the advisor could not be consulted (#{why}).
    Continue with your best judgement. When you are done, reply with your summary.
    """
  end

  def human_reply(reply) do
    """
    Alkim: answer from the user:

    #{reply}

    Continue with the task. When you are done, reply with your summary.
    """
  end

  @doc "Prompt for an ephemeral consultant."
  def advisor(ctx, reason, question) do
    """
    You are an ADVISOR consulted by a coding agent through Alkim. Do not modify any
    files; you may read the workspace to ground your answer.

    Workspace: #{ctx.workspace}

    ## Overall task the agent is working on
    #{ctx.task}
    #{constraints(ctx)}
    ## Question (#{reason})
    #{question}

    Answer concisely with a concrete recommendation and the main trade-offs.
    """
  end

  @doc "Prompt for a fresh, independent reviewer."
  def auditor(ctx) do
    """
    You are an independent AUDITOR in a Alkim workflow. Do NOT modify any files.
    Review the work another agent did for the task below. Read the files and run
    read-only checks if your permissions allow.

    Workspace: #{ctx.workspace}
    Audit round: #{ctx.round}

    ## Task
    #{ctx.task}
    #{constraints(ctx)}
    ## Implementation summary (from the implementer)
    #{ctx.summary || "(none)"}

    ## Changed files
    #{changed_files(ctx.changed_files)}
    #{diff(ctx.diff)}
    Report only issues that must be fixed for the task to be correctly done
    (bugs, missing requirements, security problems, broken tests, violated
    constraints). End your reply with exactly one block:

    <alkim:audit>{"status": "passed", "findings": []}</alkim:audit>

    or, if there are issues:

    <alkim:audit>{"status": "findings", "findings": [{"severity": "critical|high|medium|low", "title": "...", "description": "...", "file": "path or null", "line": 1}]}</alkim:audit>
    """
  end

  def format_findings([]), do: "(no findings)"

  def format_findings(findings) do
    findings
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {%Finding{} = f, i} ->
      location = if f.file, do: " (#{f.file}#{if f.line, do: ":#{f.line}"})", else: ""

      "#{i}. [#{f.severity}] #{f.title}#{location}" <>
        if(f.description, do: "\n   #{f.description}", else: "")
    end)
  end

  defp constraints(%{constraints: c}) when is_binary(c) and c != "",
    do: "\n## Architectural constraints\n#{c}\n"

  defp constraints(_), do: ""

  defp advisor_instructions(%{advisor: %{max_calls: max, allowed_reasons: reasons}})
       when max > 0 do
    """

    If you need a second opinion before continuing (at most #{max} times), end your reply with
    <alkim:ask-advisor reason="REASON">your question</alkim:ask-advisor>
    and stop, where REASON is one of: #{Enum.join(reasons, ", ")}.
    Alkim will send you the advisor's answer.
    """
  end

  defp advisor_instructions(_), do: ""

  defp changed_files(nil),
    do: "(unknown: the workspace is not a git repository — inspect it directly)"

  defp changed_files([]), do: "(git reports no changes)"
  defp changed_files(files), do: Enum.map_join(files, "\n", &"- #{&1}")

  defp diff(nil), do: ""
  defp diff(""), do: ""

  defp diff(diff),
    do:
      "\n## Diff of tracked files (new files are not included; read them directly)\n```diff\n#{diff}\n```\n"
end
