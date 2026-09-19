defmodule Khymeia.Providers.Secrets do
  @moduledoc """
  Where provider credentials live when they are not ambient.

  The default backend is the macOS Keychain (`Khymeia.Providers.Keychain`).
  Khymeia only stores *which* item to read; the value is fetched when a turn
  starts and handed to the harness process environment, nothing else.
  """

  @callback available?() :: boolean()
  @callback put(account :: String.t(), secret :: String.t()) :: :ok | {:error, term()}
  @callback get(account :: String.t()) :: {:ok, String.t()} | {:error, :not_found | term()}
  @callback exists?(account :: String.t()) :: boolean()
  @callback delete(account :: String.t()) :: :ok

  def backend, do: Application.get_env(:khymeia, :secrets_backend, Khymeia.Providers.Keychain)

  def available?, do: backend().available?()
  def put(account, secret), do: backend().put(account, secret)
  def get(account), do: backend().get(account)
  def exists?(account), do: backend().exists?(account)
  def delete(account), do: backend().delete(account)

  @doc "Rejects values that could not be a key/token (or could break quoting)."
  def valid_secret?(secret) when is_binary(secret),
    do: Regex.match?(~r/\A[A-Za-z0-9._~+\/=:-]{8,4096}\z/, secret)

  def valid_secret?(_), do: false
end
