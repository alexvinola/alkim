defmodule Alkim.Providers.Profile do
  @moduledoc """
  A *provider profile*: run an installed harness against a cloud model
  provider instead of its default one. The harness still runs locally with
  its own agent loop and tools; only model inference goes to the provider.

  | harness | kind            | what it means                                   |
  |---------|-----------------|-------------------------------------------------|
  | claude  | `:bedrock`      | Claude models on Amazon Bedrock                 |
  | claude  | `:foundry`      | Claude models on Microsoft Foundry              |
  | claude  | `:vertex`       | Claude models on Google Vertex AI               |
  | codex   | `:azure_openai` | OpenAI models on Azure OpenAI / Foundry         |
  | codex   | `:bedrock`      | models on Amazon Bedrock (Codex's built-in `amazon-bedrock` provider) |

  Only non-secret settings are stored. The credential is either *ambient*
  (the provider SDK's own chain: an AWS profile, `az login`, gcloud ADC),
  the name of an environment variable of the Alkim process (`:env`), an
  API key in the macOS Keychain (`:keychain`), or AWS access keys in the
  macOS Keychain (`:aws_keys`, entered in a form instead of editing
  `~/.aws/credentials`). Keychain items are read when a turn starts. Secrets
  never reach the database, logs or events.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  @kinds %{
    claude: [:bedrock, :foundry, :vertex],
    codex: [:azure_openai, :bedrock],
    # Demo/test only: proves a profile reaches the harness process.
    fake: [:demo]
  }

  @settings %{
    {:claude, :bedrock} => ~w(region aws_profile base_url),
    {:claude, :foundry} => ~w(resource base_url),
    {:claude, :vertex} => ~w(project_id region credentials_file),
    {:codex, :azure_openai} => ~w(base_url),
    {:codex, :bedrock} => ~w(region aws_profile),
    {:fake, :demo} => ~w(region)
  }

  # Which credential sources make sense for each combination.
  @credentials %{
    {:claude, :bedrock} => [:ambient, :aws_keys, :keychain, :env],
    {:claude, :foundry} => [:ambient, :env, :keychain],
    {:claude, :vertex} => [:ambient],
    {:codex, :azure_openai} => [:env, :keychain],
    {:codex, :bedrock} => [:ambient, :aws_keys],
    {:fake, :demo} => [:ambient, :env, :keychain, :aws_keys]
  }

  schema "provider_profiles" do
    field :name, :string
    field :harness, Ecto.Enum, values: Map.keys(@kinds)
    field :kind, Ecto.Enum, values: [:bedrock, :foundry, :vertex, :azure_openai, :demo]
    field :settings, :map, default: %{}
    field :default_model, :string

    field :credential, Ecto.Enum,
      values: [:ambient, :env, :keychain, :aws_keys],
      default: :ambient

    field :credential_env, :string

    timestamps()
  end

  def kinds, do: @kinds

  @doc "Whether the credential lives in the Keychain."
  def stored_secret?(%__MODULE__{credential: c}), do: c in [:keychain, :aws_keys]
  def setting_keys(harness, kind), do: Map.get(@settings, {harness, kind}, [])
  def credential_options(harness, kind), do: Map.get(@credentials, {harness, kind}, [:ambient])

  def kind_label(:bedrock), do: "Amazon Bedrock"
  def kind_label(:foundry), do: "Microsoft Foundry"
  def kind_label(:vertex), do: "Google Vertex AI"
  def kind_label(:azure_openai), do: "Azure OpenAI / Foundry"
  def kind_label(:demo), do: "Demo provider"

  @doc "Whether sessions must name a model/deployment (no usable harness default)."
  def requires_model?(%__MODULE__{harness: :codex}), do: true
  def requires_model?(%__MODULE__{harness: :claude, kind: :foundry}), do: true
  def requires_model?(_), do: false

  def label(%__MODULE__{} = p), do: "#{kind_label(p.kind)} · #{p.name}"

  @name ~r/\A[A-Za-z0-9][A-Za-z0-9 ._-]{0,47}\z/
  @env_name ~r/\A[A-Z_][A-Z0-9_]{0,63}\z/
  @plain ~r/\A[A-Za-z0-9._:\/@-]{1,255}\z/

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [
      :name,
      :harness,
      :kind,
      :settings,
      :default_model,
      :credential,
      :credential_env
    ])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :harness, :kind, :credential])
    |> validate_format(:name, @name, message: "letters, digits, spaces, . _ - (max 48)")
    |> validate_format(:default_model, @plain, message: "invalid model or deployment name")
    |> validate_kind()
    |> clean_settings()
    |> validate_settings()
    |> validate_credential()
    |> unique_constraint(:name)
  end

  defp validate_kind(changeset) do
    harness = get_field(changeset, :harness)
    kind = get_field(changeset, :kind)

    if harness && kind && kind not in Map.get(@kinds, harness, []),
      do: add_error(changeset, :kind, "not supported by this harness"),
      else: changeset
  end

  # Keep only the known keys for the combination, trimmed, without blanks.
  # An AWS profile is meaningless unless credentials come from the AWS chain.
  defp clean_settings(changeset) do
    keys = setting_keys(get_field(changeset, :harness), get_field(changeset, :kind))

    keys =
      if get_field(changeset, :credential) == :ambient, do: keys, else: keys -- ["aws_profile"]

    settings =
      for {k, v} <- get_field(changeset, :settings) || %{},
          (k = to_string(k)) in keys,
          (v = v |> to_string() |> String.trim()) != "",
          into: %{},
          do: {k, v}

    put_change(changeset, :settings, settings)
  end

  defp validate_settings(changeset) do
    s = get_field(changeset, :settings)

    case {get_field(changeset, :harness), get_field(changeset, :kind)} do
      {:claude, :bedrock} ->
        changeset
        |> check(s, "region", &region?/1)
        |> check(s, "aws_profile", &plain?/1)
        |> check(s, "base_url", &https?/1)

      {:claude, :foundry} ->
        changeset
        |> require_one(s, ["resource", "base_url"], "set the resource name or the base URL")
        |> check(s, "resource", &plain?/1)
        |> check(s, "base_url", &https?/1)

      {:claude, :vertex} ->
        changeset
        |> require_one(s, ["project_id"], "the project id is required")
        |> check(s, "project_id", &plain?/1)
        |> check(s, "region", &region?/1)
        |> check(s, "credentials_file", &(String.starts_with?(&1, "/") and plain?(&1)))

      {:codex, :azure_openai} ->
        changeset
        |> require_one(s, ["base_url"], "the endpoint URL is required")
        |> check(s, "base_url", &azure_v1?/1)

      {:codex, :bedrock} ->
        changeset
        |> require_one(s, ["region"], "the region is required")
        |> check(s, "region", &region?/1)
        |> check(s, "aws_profile", &plain?/1)

      _ ->
        changeset
    end
  end

  defp validate_credential(changeset) do
    harness = get_field(changeset, :harness)
    kind = get_field(changeset, :kind)
    credential = get_field(changeset, :credential)

    changeset =
      if harness && kind && credential not in credential_options(harness, kind),
        do: add_error(changeset, :credential, "not available for this provider"),
        else: changeset

    if credential == :env do
      changeset
      |> validate_required([:credential_env], message: "name the environment variable")
      |> validate_format(:credential_env, @env_name, message: "e.g. AZURE_OPENAI_API_KEY")
    else
      put_change(changeset, :credential_env, nil)
    end
  end

  defp check(changeset, settings, key, fun) do
    case settings[key] do
      nil ->
        changeset

      value ->
        if fun.(value),
          do: changeset,
          else: add_error(changeset, :settings, "invalid #{key}: #{value}")
    end
  end

  defp require_one(changeset, settings, keys, message) do
    if Enum.any?(keys, &Map.has_key?(settings, &1)),
      do: changeset,
      else: add_error(changeset, :settings, message)
  end

  # Values end up in environment variables or TOML strings: keep them plain.
  defp plain?(v), do: Regex.match?(@plain, v)
  defp region?(v), do: Regex.match?(~r/\A[a-z]{2,}(-[a-z0-9]+)*\z/, v)

  defp https?(v) do
    case URI.parse(v) do
      %URI{scheme: "https", host: host, query: nil} when is_binary(host) and host != "" ->
        not String.contains?(v, ["\"", "\\", " "])

      _ ->
        false
    end
  end

  # Codex needs the v1 API path (no api-version query needed).
  defp azure_v1?(v),
    do: https?(v) and String.ends_with?(String.trim_trailing(v, "/"), "/openai/v1")
end
