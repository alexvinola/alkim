defmodule Khymeia.MemorySecrets do
  @moduledoc "In-memory secrets backend for tests — never touches the real Keychain."
  @behaviour Khymeia.Providers.Secrets

  use Agent

  def start_link(_), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  @impl true
  def available?, do: true

  @impl true
  def put(account, secret) do
    if Khymeia.Providers.Secrets.valid_secret?(secret),
      do: Agent.update(__MODULE__, &Map.put(&1, account, secret)),
      else: {:error, :invalid_secret}
  end

  @impl true
  def get(account) do
    case Agent.get(__MODULE__, &Map.get(&1, account)) do
      nil -> {:error, :not_found}
      secret -> {:ok, secret}
    end
  end

  @impl true
  def exists?(account), do: Agent.get(__MODULE__, &Map.has_key?(&1, account))

  @impl true
  def delete(account), do: Agent.update(__MODULE__, &Map.delete(&1, account))
end
