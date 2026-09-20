defmodule AlkimWeb.HarnessOptions do
  @moduledoc """
  The harness `<select>` options shared by the Chat and Workflow forms:
  every available harness, each followed by its provider profiles, then the
  harnesses that cannot be used (disabled, with the reason).
  """

  alias Alkim.Providers

  @type option :: %{
          value: String.t(),
          label: String.t(),
          disabled: boolean(),
          harness: map() | nil,
          profile: Alkim.Providers.Profile.t() | nil
        }

  @spec build([map()]) :: [option()]
  def build(harnesses) do
    available = Enum.filter(harnesses, &(&1.status == :available))

    usable =
      for choice <- Providers.choices(available) do
        Map.merge(choice, %{disabled: false})
      end

    unusable =
      for h <- harnesses, h.status != :available do
        %{
          value: Atom.to_string(h.id),
          label: "#{h.name} — #{reason(h.status)}",
          disabled: true,
          harness: nil,
          profile: nil
        }
      end

    usable ++ unusable
  end

  def find(options, value), do: Enum.find(options, &(&1.value == value and not &1.disabled))

  @doc """
  Only the options whose adapter knows how to start the harness's own TUI.
  Alkim never guesses an interactive command line.
  """
  def interactive(options) do
    Enum.filter(options, fn option ->
      option.harness && function_exported?(option.harness.adapter, :build_interactive, 1)
    end)
  end

  @doc "Models offered for an option (see `Alkim.Providers.models/2`)."
  def models(%{profile: nil, harness: h}), do: h.models
  def models(%{profile: p, harness: h}), do: Providers.models(p, h.models)

  def first_value(options) do
    case Enum.find(options, &(not &1.disabled)) do
      nil -> ""
      option -> option.value
    end
  end

  defp reason(:not_installed), do: "not installed"
  defp reason(:no_adapter), do: "no adapter yet"
end
