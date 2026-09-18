defmodule Khymeia.Harness.Summary do
  @moduledoc false
  # Short, single-line renderings of tool inputs for the activity log.

  @max 160

  def input(nil), do: ""

  def input(%{} = input) do
    preferred = ~w(command file_path path pattern url query description prompt)

    case Enum.find_value(preferred, &input[&1]) do
      nil -> input |> Jason.encode!() |> truncate()
      value -> value |> to_string() |> truncate()
    end
  end

  def input(other), do: other |> inspect() |> truncate()

  def truncate(text) do
    text = text |> String.replace(~r/\s+/, " ") |> String.trim()
    if String.length(text) > @max, do: String.slice(text, 0, @max) <> "…", else: text
  end
end
