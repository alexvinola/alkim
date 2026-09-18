defmodule Khymeia.Runtime.Registry do
  @moduledoc """
  Names session processes by session id, using Elixir's `Registry`.

  Each session also keeps a small summary as its registry value (harness,
  status, timestamps). Listing active sessions therefore reads an ETS table
  instead of calling every session process — a slow or busy session can
  never block the dashboard.
  """

  @name __MODULE__

  def child_spec(_opts), do: Registry.child_spec(keys: :unique, name: @name)

  @doc "A `:via` name that registers the process with its initial summary."
  def via(id, summary \\ %{}), do: {:via, Registry, {@name, id, summary}}

  @spec lookup(String.t()) :: {:ok, pid()} | :error
  def lookup(id) do
    case Registry.lookup(@name, id) do
      [{pid, _summary}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc "Replaces the caller's own summary. Only the owning process may do this."
  def put_summary(id, summary) do
    Registry.update_value(@name, id, fn _ -> summary end)
    :ok
  end

  @doc "All registered sessions as `{id, pid, summary}`."
  @spec list() :: [{String.t(), pid(), map()}]
  def list, do: Registry.select(@name, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])

  def count, do: Registry.count(@name)
end
