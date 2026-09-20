defmodule Alkim.Workflow.Protocol do
  @moduledoc """
  The adaptation layer between free-form harness output and the workflow.

  Harnesses do not share a structured-output format (and some have none), so
  roles are asked to end their reply with a small tagged block that any
  model can produce and any harness can transport as plain text:

      <alkim:ask-advisor reason="architecture">question</alkim:ask-advisor>
      <alkim:ask-human>question</alkim:ask-human>
      <alkim:audit>{"status": "passed" | "findings", "findings": [...]}</alkim:audit>

  Parsing is deterministic: the last block wins, JSON code fences inside the
  audit block are tolerated, anything else is `:none` / `:unparseable`.
  Harness-native structured output (e.g. JSON schemas) can replace this
  per adapter later without touching the workflow engine.
  """

  alias Alkim.Workflow.{AuditResult, Finding}

  @ask_advisor ~r{<alkim:ask-advisor(?:\s+reason="([^"]*)")?\s*>(.*?)</alkim:ask-advisor>}s
  @ask_human ~r{<alkim:ask-human>(.*?)</alkim:ask-human>}s
  @audit ~r{<alkim:audit>(.*?)</alkim:audit>}s

  @type request ::
          {:ask_advisor, reason :: String.t(), question :: String.t()}
          | {:ask_human, question :: String.t()}
          | :none

  @doc "Finds the request (if any) an implementer ended its turn with."
  @spec parse_request(String.t()) :: request()
  def parse_request(text) when is_binary(text) do
    advisor = last_match(@ask_advisor, text)
    human = last_match(@ask_human, text)

    case {advisor, human} do
      {nil, nil} ->
        :none

      {{pos_a, [_, reason, question]}, h} when h == nil or elem(h, 0) < pos_a ->
        {:ask_advisor, blank_default(reason, "unspecified"), String.trim(question)}

      {_, {_, [_, question]}} ->
        {:ask_human, String.trim(question)}
    end
  end

  def parse_request(_), do: :none

  @doc "Reads a reviewer verdict."
  @spec parse_audit(String.t()) :: AuditResult.t()
  def parse_audit(text) when is_binary(text) do
    with {_, [_, body]} <- last_match(@audit, text),
         {:ok, %{"status" => status} = map} <- body |> strip_fences() |> Jason.decode(),
         findings when is_list(findings) <- Map.get(map, "findings", []) do
      findings = for f <- findings, is_map(f), do: Finding.from_map(f)

      status =
        case String.downcase(to_string(status)) do
          "passed" -> :passed
          s when s in ["findings", "failed"] and findings != [] -> :findings
          s when s in ["findings", "failed"] -> :passed
          _ -> :unparseable
        end

      %AuditResult{status: status, findings: findings, raw: text}
    else
      _ -> %AuditResult{status: :unparseable, raw: text}
    end
  end

  def parse_audit(_), do: %AuditResult{status: :unparseable}

  @doc "Removes protocol blocks from text shown to humans."
  def strip(text) when is_binary(text) do
    text
    |> String.replace(@audit, "")
    |> String.replace(@ask_advisor, "")
    |> String.replace(@ask_human, "")
    |> String.trim()
  end

  defp last_match(regex, text) do
    case Regex.scan(regex, text, return: :index) do
      [] ->
        nil

      matches ->
        [{pos, _} | _] = indexes = List.last(matches)
        {pos, Enum.map(indexes, fn {s, l} -> if s < 0, do: "", else: binary_part(text, s, l) end)}
    end
  end

  defp strip_fences(body) do
    body
    |> String.trim()
    |> String.replace(~r/\A```(?:json)?\s*/, "")
    |> String.replace(~r/\s*```\z/, "")
  end

  defp blank_default("", default), do: default
  defp blank_default(value, _default), do: String.trim(value)
end
