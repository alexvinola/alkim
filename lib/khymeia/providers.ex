defmodule Khymeia.Providers do
  @moduledoc """
  Provider profiles: installed harnesses running against cloud model
  providers (Amazon Bedrock, Microsoft Foundry, Google Vertex AI, Azure
  OpenAI). See `Khymeia.Providers.Profile`.

  A harness *choice* in the UI and API is either `"claude"` (the harness with
  its own configuration) or `"claude@<profile id>"`.
  """

  import Ecto.Query

  alias Khymeia.Repo
  alias Khymeia.Providers.{Profile, Secrets}

  ## CRUD

  def list, do: Profile |> order_by(:name) |> Repo.all()

  def get(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(Profile, uuid)
      :error -> nil
    end
  end

  def change(profile \\ %Profile{}, attrs \\ %{}), do: Profile.changeset(profile, attrs)

  @doc """
  Creates or updates a profile. With `credential: :keychain`, a non-empty
  `secret` is written to the Keychain (never to the database); an empty one
  keeps the stored item.
  """
  def save(attrs) when is_map(attrs), do: save(%Profile{}, attrs, nil)
  def save(%Profile{} = profile, attrs), do: save(profile, attrs, nil)
  def save(attrs, secret) when is_map(attrs), do: save(%Profile{}, attrs, secret)

  def save(%Profile{} = profile, attrs, secret) do
    changeset = Profile.changeset(profile, attrs)

    Repo.transaction(fn ->
      with {:ok, saved} <- Repo.insert_or_update(changeset),
           :ok <- store_secret(saved, secret) do
        saved
      else
        {:error, %Ecto.Changeset{} = cs} ->
          Repo.rollback(cs)

        {:error, reason} ->
          Repo.rollback(Ecto.Changeset.add_error(changeset, :secret, secret_error(reason)))
      end
    end)
  end

  @doc "Removes the stored credential (the profile stays, and warns until a new one is saved)."
  def forget_secret(%Profile{} = profile), do: Secrets.delete(account(profile))

  @doc """
  Validates AWS access keys typed in a form and packs them for the
  Keychain. Returns `:blank` when nothing was typed (keep the stored keys).
  """
  def pack_aws_keys(params) do
    id = params |> Map.get("aws_access_key_id", "") |> to_string() |> String.trim()
    key = params |> Map.get("aws_secret_access_key", "") |> to_string() |> String.trim()
    token = params |> Map.get("aws_session_token", "") |> to_string() |> String.trim()

    cond do
      id == "" and key == "" and token == "" ->
        :blank

      not Regex.match?(~r/\A[A-Z0-9]{16,128}\z/, id) ->
        {:error, "the access key ID looks wrong (e.g. AKIA…)"}

      not Regex.match?(~r/\A[A-Za-z0-9\/+=]{16,256}\z/, key) ->
        {:error, "the secret access key looks wrong"}

      token != "" and not Regex.match?(~r/\A[A-Za-z0-9\/+=]{16,4000}\z/, token) ->
        {:error, "the session token looks wrong"}

      true ->
        {:ok, Enum.join([id, key | if(token == "", do: [], else: [token])], ":")}
    end
  end

  def delete(%Profile{} = profile) do
    Secrets.delete(account(profile))
    Repo.delete(profile)
  end

  defp store_secret(%Profile{credential: c} = profile, secret)
       when c in [:keychain, :aws_keys] and secret not in [nil, ""],
       do: Secrets.put(account(profile), secret)

  defp store_secret(%Profile{credential: c} = profile, _none) when c in [:keychain, :aws_keys] do
    cond do
      Secrets.exists?(account(profile)) -> :ok
      c == :aws_keys -> {:error, :missing_aws_keys}
      true -> {:error, :missing_secret}
    end
  end

  defp store_secret(profile, _secret) do
    # Switching away from the Keychain removes the stored item.
    Secrets.delete(account(profile))
    :ok
  end

  defp secret_error(:missing_secret), do: "paste the API key to store it in the Keychain"
  defp secret_error(:missing_aws_keys), do: "enter the access key ID and secret access key"
  defp secret_error(:invalid_secret), do: "this does not look like an API key"
  defp secret_error(:unavailable), do: "the macOS Keychain is not available on this system"
  defp secret_error(other), do: "could not store the secret: #{inspect(other)}"

  defp account(%Profile{id: id}), do: "profile:#{id}"

  ## Choices

  @doc """
  Harness choices for forms: each available harness, followed by its
  profiles. `%{value, label, harness, profile}`.
  """
  def choices(available_harnesses) do
    profiles = list()

    Enum.flat_map(available_harnesses, fn h ->
      own =
        for p <- profiles,
            p.harness == h.id,
            do: %{
              value: "#{h.id}@#{p.id}",
              label: "#{h.name} · #{Profile.label(p)}",
              harness: h,
              profile: p
            }

      [%{value: Atom.to_string(h.id), label: h.name, harness: h, profile: nil} | own]
    end)
  end

  @doc "Splits `\"claude@<id>\"` into `{\"claude\", profile_id}`."
  def parse_choice(nil), do: {nil, nil}

  def parse_choice(value) do
    case String.split(to_string(value), "@", parts: 2) do
      [harness, profile] -> {harness, profile}
      [harness] -> {harness, nil}
    end
  end

  @doc """
  Models to offer for a profile. Only what is known for sure: the profile's
  default model, plus Claude Code's aliases where the docs say they resolve
  on that provider (Bedrock, Vertex). Anything else is typed by the user.
  """
  def models(%Profile{} = p, harness_models) do
    default =
      if p.default_model,
        do: [%{id: p.default_model, name: p.default_model, description: "profile default"}],
        else: []

    aliases =
      if p.harness == :claude and p.kind in [:bedrock, :vertex], do: harness_models, else: []

    Enum.uniq_by(default ++ aliases, & &1.id)
  end

  ## Launch

  @doc """
  Everything an adapter needs to point its harness at the provider, with
  the secret (if any) resolved now. Returns a map for the turn:
  `%{kind, settings, secret, name}`.
  """
  @spec resolve(String.t()) :: {:ok, map()} | {:error, String.t()}
  def resolve(profile_id) do
    with %Profile{} = p <- get(profile_id) || {:error, "provider profile no longer exists"},
         {:ok, secret} <- fetch_secret(p) do
      {:ok, %{kind: p.kind, settings: p.settings, secret: secret, name: p.name}}
    end
  end

  defp fetch_secret(%Profile{credential: :ambient}), do: {:ok, nil}

  defp fetch_secret(%Profile{credential: :env, credential_env: var}) do
    case System.get_env(var) do
      value when value not in [nil, ""] -> {:ok, value}
      _ -> {:error, "environment variable #{var} is not set in Khymeia's environment"}
    end
  end

  defp fetch_secret(%Profile{credential: :aws_keys} = p) do
    with {:ok, packed} <- Secrets.get(account(p)),
         [id, key | token] <- String.split(packed, ":") do
      {:ok, %{access_key_id: id, secret_access_key: key, session_token: List.first(token)}}
    else
      _ -> {:error, "the AWS access keys for #{p.name} are not in the Keychain"}
    end
  end

  defp fetch_secret(%Profile{credential: :keychain} = p) do
    case Secrets.get(account(p)) do
      {:ok, secret} -> {:ok, secret}
      {:error, _} -> {:error, "the API key for #{p.name} is not in the Keychain"}
    end
  end

  ## Readiness

  @doc """
  Local checks only — no network call, no cost. Each item is
  `{:ok | :warn, text}`. A real request is the only full test.
  """
  def readiness(%Profile{} = p) do
    credential_checks(p) ++ provider_checks(p)
  end

  defp credential_checks(%Profile{credential: :env, credential_env: var}) do
    if System.get_env(var) in [nil, ""],
      do: [
        {:warn,
         "#{var} is not set in Khymeia's environment (a brew services daemon does not see your shell's variables)"}
      ],
      else: [{:ok, "#{var} is set"}]
  end

  defp credential_checks(%Profile{credential: :aws_keys} = p) do
    if Secrets.exists?(account(p)),
      do: [{:ok, "AWS access keys stored in the macOS Keychain"}],
      else: [{:warn, "no AWS access keys in the Keychain for this profile"}]
  end

  defp credential_checks(%Profile{credential: :keychain} = p) do
    if Secrets.exists?(account(p)),
      do: [{:ok, "API key stored in the macOS Keychain"}],
      else: [{:warn, "no API key in the Keychain for this profile"}]
  end

  defp credential_checks(_ambient), do: []

  defp provider_checks(%Profile{kind: :bedrock, credential: :ambient, settings: s}) do
    profile = s["aws_profile"] || System.get_env("AWS_PROFILE") || "default"

    if aws_profile?(profile),
      do: [{:ok, "AWS profile \"#{profile}\" found in ~/.aws"}],
      else: [
        {:warn, "AWS profile \"#{profile}\" not found in ~/.aws/config or ~/.aws/credentials"}
      ]
  end

  defp provider_checks(%Profile{kind: :foundry, credential: :ambient}) do
    if System.find_executable("az"),
      do: [{:ok, "uses the Azure default credential chain (e.g. `az login`)"}],
      else: [
        {:warn,
         "no API key and no Azure CLI found: Entra ID needs a credential in the Azure default chain"}
      ]
  end

  defp provider_checks(%Profile{kind: :vertex, settings: s}) do
    file =
      s["credentials_file"] ||
        Path.expand("~/.config/gcloud/application_default_credentials.json")

    if File.regular?(file),
      do: [{:ok, "Google credentials found (#{Path.basename(file)})"}],
      else: [
        {:warn,
         "no Google credentials: run `gcloud auth application-default login` or set a credentials file"}
      ]
  end

  defp provider_checks(_), do: []

  defp aws_profile?(name) do
    config = read(System.get_env("AWS_CONFIG_FILE") || "~/.aws/config")
    credentials = read(System.get_env("AWS_SHARED_CREDENTIALS_FILE") || "~/.aws/credentials")

    String.contains?(config, "[profile #{name}]") or String.contains?(credentials, "[#{name}]") or
      (name == "default" and String.contains?(config, "[default]"))
  end

  defp read(path) do
    case File.read(Path.expand(path)) do
      {:ok, content} -> content
      _ -> ""
    end
  end
end
