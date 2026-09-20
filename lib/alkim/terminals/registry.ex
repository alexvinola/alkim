defmodule Alkim.Terminals.Registry do
  @moduledoc "Names terminal processes by terminal id."

  @name __MODULE__

  def child_spec(_opts), do: Registry.child_spec(keys: :unique, name: @name)

  def via(id), do: {:via, Registry, {@name, id}}

  @spec lookup(String.t()) :: {:ok, pid()} | :error
  def lookup(id) do
    case Registry.lookup(@name, id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  def count, do: Registry.count(@name)
end
