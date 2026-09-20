defmodule AlkimWeb.ProvidersLive do
  @moduledoc """
  Provider profiles: run an installed harness against Amazon Bedrock,
  Microsoft Foundry, Google Vertex AI or Azure OpenAI.

  The harness keeps running locally (agent loop, tools, files); only model
  inference goes to the provider. Secrets are never stored by Alkim: they
  stay ambient (AWS profile, `az login`, gcloud ADC), in an environment
  variable of the Alkim process, or in the macOS Keychain.
  """

  use AlkimWeb, :live_view

  alias Alkim.{Harness, Providers}
  alias Alkim.Providers.{Profile, Secrets}

  @fields %{
    "region" => {"Region", "e.g. us-east-1 / eu-central-1 / global"},
    "aws_profile" =>
      {"AWS profile", "from ~/.aws/config (optional; else AWS_PROFILE or default)"},
    "base_url" => {"Base URL", nil},
    "resource" => {"Resource name", "the Foundry resource name"},
    "project_id" => {"Project ID", "Google Cloud project"},
    "credentials_file" =>
      {"Credentials file", "optional absolute path (GOOGLE_APPLICATION_CREDENTIALS)"}
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Providers · Alkim") |> load()}
  end

  @impl true
  def handle_params(%{"edit" => id}, _uri, socket) do
    case Providers.get(id) do
      nil -> {:noreply, push_patch(socket, to: ~p"/providers")}
      profile -> {:noreply, edit(socket, profile)}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, edit(socket, nil)}

  @impl true
  def handle_event("change", %{"profile" => params}, socket) do
    {:noreply, assign_form(socket, params)}
  end

  def handle_event("save", %{"profile" => params}, socket) do
    {secret, params} = Map.pop(params, "secret")

    {aws, params} =
      Map.split(params, ~w(aws_access_key_id aws_secret_access_key aws_session_token))

    profile = socket.assigns.editing || %Profile{}

    secret =
      if params["credential"] == "aws_keys" do
        case Providers.pack_aws_keys(aws) do
          :blank -> {:ok, nil}
          other -> other
        end
      else
        {:ok, secret}
      end

    case secret do
      {:ok, secret} ->
        save(socket, profile, params, secret)

      {:error, message} ->
        {:noreply, socket |> assign(errors: %{secret: message}) |> assign_form(params)}
    end
  end

  def handle_event("forget", %{"id" => id}, socket) do
    case Providers.get(id) do
      %Profile{} = profile ->
        Providers.forget_secret(profile)

        {:noreply,
         socket |> put_flash(:info, "Removed the stored credential of #{profile.name}") |> load()}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with %Profile{} = profile <- Providers.get(id), {:ok, _} <- Providers.delete(profile) do
      {:noreply,
       socket
       |> put_flash(:info, "Deleted #{profile.name}")
       |> load()
       |> push_patch(to: ~p"/providers")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not delete the profile")}
    end
  end

  defp save(socket, profile, params, secret) do
    case Providers.save(profile, attrs(params), secret) do
      {:ok, saved} ->
        {:noreply,
         socket
         |> put_flash(:info, "Saved #{saved.name}")
         |> load()
         |> push_patch(to: ~p"/providers")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, socket |> assign(errors: errors(changeset)) |> assign_form(params)}
    end
  end

  # Readiness depends on the Keychain and the environment, not only on the
  # rows, so it is recomputed here rather than inside the template (where an
  # unchanged profile list would not re-render it).
  defp load(socket) do
    profiles = Providers.list()

    assign(socket,
      profiles: profiles,
      readiness: Map.new(profiles, &{&1.id, Providers.readiness(&1)}),
      targets: targets()
    )
  end

  defp edit(socket, profile) do
    params =
      case profile do
        nil ->
          %{
            "target" => socket.assigns.targets |> List.first({nil, nil}) |> elem(0),
            "credential" => "ambient",
            "settings" => %{}
          }

        p ->
          %{
            "name" => p.name,
            "target" => "#{p.harness}:#{p.kind}",
            "settings" => p.settings,
            "default_model" => p.default_model,
            "credential" => Atom.to_string(p.credential),
            "credential_env" => p.credential_env
          }
      end

    socket |> assign(editing: profile, errors: %{}) |> assign_form(params)
  end

  defp assign_form(socket, params) do
    {harness, kind} = target(params["target"])
    options = if harness, do: Profile.credential_options(harness, kind), else: []
    options = if Secrets.available?(), do: options, else: options -- [:keychain]

    credential =
      case params["credential"] do
        c when is_binary(c) and c != "" -> String.to_existing_atom(c)
        _ -> List.first(options)
      end

    credential = if credential in options, do: credential, else: List.first(options)

    assign(socket,
      params: Map.put(params, "credential", credential && Atom.to_string(credential)),
      harness: harness,
      kind: kind,
      # The AWS profile only matters when credentials come from the AWS chain.
      setting_keys:
        ((harness && Profile.setting_keys(harness, kind)) || [])
        |> Enum.reject(&(&1 == "aws_profile" and credential != :ambient)),
      credential_options: options,
      credential: credential
    )
  end

  # Only combinations whose harness is enabled in this installation.
  defp targets do
    enabled = MapSet.new(Harness.adapters(), & &1.id())

    for {harness, kinds} <- Profile.kinds(), harness in enabled, kind <- kinds do
      {"#{harness}:#{kind}", "#{harness_name(harness)} → #{Profile.kind_label(kind)}"}
    end
  end

  defp target(nil), do: {nil, nil}

  defp target(value) do
    case String.split(value, ":") do
      [h, k] -> {String.to_existing_atom(h), String.to_existing_atom(k)}
      _ -> {nil, nil}
    end
  rescue
    ArgumentError -> {nil, nil}
  end

  defp attrs(params) do
    {harness, kind} = target(params["target"])

    %{
      "name" => params["name"],
      "harness" => harness,
      "kind" => kind,
      "settings" => params["settings"] || %{},
      "default_model" => blank(params["default_model"]),
      "credential" => params["credential"],
      "credential_env" => blank(params["credential_env"])
    }
  end

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)
    |> Map.new(fn {field, messages} -> {field, Enum.join(messages, "; ")} end)
  end

  defp harness_name(id) do
    case Harness.fetch_adapter(id) do
      {:ok, adapter} -> adapter.name()
      :error -> to_string(id)
    end
  end

  defp blank(nil), do: nil
  defp blank(v), do: if(String.trim(v) == "", do: nil, else: String.trim(v))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} nav={@nav} active={:providers}>
      <div class="a-section-head">
        <h1 class="a-h1">Providers</h1>
      </div>
      <p class="a-muted" style="max-width:48rem;margin:-.25rem 0 1.5rem">
        Run an installed harness against your own cloud: the CLI still runs here, with its agent
        loop, tools and permissions; only model inference goes to the provider, billed by it.
        Alkim never calls these providers itself and never stores secrets.
      </p>

      <section class="a-section" id="profiles">
        <div class="a-panel a-rows">
          <div :if={@profiles == []} class="a-empty">No provider profiles yet.</div>
          <div :for={p <- @profiles} class="a-provider" id={"profile-#{p.id}"}>
            <div class="a-provider-head">
              <strong>{p.name}</strong>
              <span class="a-tag">{harness_name(p.harness)}</span>
              <span class="a-tag">{Profile.kind_label(p.kind)}</span>
              <span class="a-hint">{credential_label(p)}</span>
              <span style="margin-left:auto;display:flex;gap:.4rem">
                <.link patch={~p"/providers?edit=#{p.id}"} class="a-btn a-btn-ghost">Edit</.link>
                <button
                  :if={Profile.stored_secret?(p)}
                  class="a-btn a-btn-ghost"
                  phx-click="forget"
                  phx-value-id={p.id}
                  data-confirm={"Remove the stored credential of #{p.name} from the Keychain?"}
                >
                  Forget credential
                </button>
                <button
                  class="a-btn a-btn-ghost a-btn-danger"
                  phx-click="delete"
                  phx-value-id={p.id}
                  data-confirm={"Delete #{p.name}?#{if Profile.stored_secret?(p), do: " Its stored credential is removed from the Keychain too."}"}
                >
                  Delete
                </button>
              </span>
            </div>
            <div class="a-mono a-faint a-truncate">
              {settings_summary(p)}{p.default_model && "  ·  model #{p.default_model}"}
            </div>
            <ul class="a-checks">
              <li :for={{level, text} <- @readiness[p.id]} class={"a-check-#{level}"}>
                {if level == :ok, do: "✓", else: "!"} {text}
              </li>
            </ul>
          </div>
        </div>
      </section>

      <section class="a-section">
        <div class="a-section-head">
          <h2 class="a-h2">{if @editing, do: "Edit #{@editing.name}", else: "New profile"}</h2>
          <.link :if={@editing} patch={~p"/providers"} class="a-btn a-btn-ghost">Cancel</.link>
        </div>

        <form
          id="profile-form"
          class="a-form"
          phx-change="change"
          phx-submit="save"
          autocomplete="off"
        >
          <div class="a-field-row">
            <div class="a-field">
              <label class="a-label" for="profile_name">Name</label>
              <input
                id="profile_name"
                name="profile[name]"
                value={@params["name"]}
                class="a-input"
                placeholder="e.g. bedrock-work"
              />
              <span :if={@errors[:name]} class="a-error">{@errors[:name]}</span>
            </div>
            <div class="a-field">
              <label class="a-label" for="profile_target">Harness → provider</label>
              <select
                id="profile_target"
                name="profile[target]"
                class="a-select"
                disabled={@editing != nil}
              >
                <option
                  :for={{value, label} <- @targets}
                  value={value}
                  selected={value == @params["target"]}
                >
                  {label}
                </option>
              </select>
              <input :if={@editing} type="hidden" name="profile[target]" value={@params["target"]} />
            </div>
          </div>

          <div :for={key <- @setting_keys} class="a-field">
            <label class="a-label" for={"profile_settings_#{key}"}>{field_label(key, @harness, @kind)}</label>
            <input
              id={"profile_settings_#{key}"}
              name={"profile[settings][#{key}]"}
              value={(@params["settings"] || %{})[key]}
              class="a-input a-mono"
              placeholder={field_hint(key, @harness, @kind)}
            />
          </div>
          <span :if={@errors[:settings]} class="a-error">{@errors[:settings]}</span>

          <div class="a-field">
            <label class="a-label" for="profile_default_model">{model_label(@harness, @kind)}</label>
            <input
              id="profile_default_model"
              name="profile[default_model]"
              value={@params["default_model"]}
              class="a-input a-mono"
              placeholder={model_hint(@harness, @kind)}
            />
            <span :if={@errors[:default_model]} class="a-error">{@errors[:default_model]}</span>
          </div>

          <fieldset class="a-field a-fieldset">
            <legend class="a-label">Credential</legend>
            <label :for={c <- @credential_options} class="a-radio">
              <input type="radio" name="profile[credential]" value={c} checked={c == @credential} />
              {credential_option(c, @harness, @kind)}
            </label>
            <span :if={@errors[:credential]} class="a-error">{@errors[:credential]}</span>

            <div :if={@credential == :env} class="a-field">
              <input
                name="profile[credential_env]"
                value={@params["credential_env"]}
                class="a-input a-mono"
                placeholder="AZURE_OPENAI_API_KEY"
                id="profile_credential_env"
              />
              <span class="a-hint">
                Name of a variable in Alkim's own environment. A `brew services` daemon does not see your shell's exports.
              </span>
              <span :if={@errors[:credential_env]} class="a-error">{@errors[:credential_env]}</span>
            </div>

            <div :if={@credential == :keychain} class="a-field">
              <input
                type="password"
                name="profile[secret]"
                class="a-input a-mono"
                placeholder={
                  if @editing && @editing.credential == :keychain,
                    do: "leave empty to keep the stored key",
                    else: "paste the API key"
                }
                id="profile_secret"
                autocomplete="new-password"
              />
              <span class="a-hint">Stored in your macOS Keychain (service “alkim”), never in Alkim's database.</span>
              <span :if={@errors[:secret]} class="a-error">{@errors[:secret]}</span>
            </div>

            <div :if={@credential == :aws_keys} class="a-field" id="aws-keys">
              <input
                name="profile[aws_access_key_id]"
                class="a-input a-mono"
                placeholder="Access key ID (AKIA… / ASIA…)"
                id="profile_aws_access_key_id"
                autocomplete="off"
                spellcheck="false"
              />
              <input
                type="password"
                name="profile[aws_secret_access_key]"
                class="a-input a-mono"
                placeholder="Secret access key"
                id="profile_aws_secret_access_key"
                autocomplete="new-password"
              />
              <input
                type="password"
                name="profile[aws_session_token]"
                class="a-input a-mono"
                placeholder="Session token (only for temporary credentials)"
                id="profile_aws_session_token"
                autocomplete="new-password"
              />
              <span class="a-hint">
                Stored together in your macOS Keychain and passed only to the harness process
                (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN). {if @editing &&
                                                                                       @editing.credential ==
                                                                                         :aws_keys,
                                                                                     do:
                                                                                       "Leave empty to keep the stored keys."} Prefer an IAM user limited to Bedrock, or an AWS profile/SSO when you can.
              </span>
              <span :if={@errors[:secret]} class="a-error">{@errors[:secret]}</span>
            </div>
          </fieldset>

          <div>
            <button type="submit" class="a-btn a-btn-primary" id="save-profile">
              {if @editing, do: "Save changes", else: "Create profile"}
            </button>
          </div>
        </form>
      </section>
    </Layouts.app>
    """
  end

  defp field_label("base_url", :codex, :azure_openai), do: "Endpoint (v1)"
  defp field_label(key, _h, _k), do: elem(@fields[key], 0)

  defp field_hint("base_url", :codex, :azure_openai),
    do: "https://RESOURCE.openai.azure.com/openai/v1"

  defp field_hint("base_url", :claude, :foundry),
    do: "https://RESOURCE.services.ai.azure.com/anthropic (or set the resource name)"

  defp field_hint("base_url", :claude, :bedrock), do: "optional custom endpoint or gateway"
  defp field_hint(key, _h, _k), do: elem(@fields[key], 1)

  defp model_label(:codex, :azure_openai), do: "Default deployment"
  defp model_label(:claude, :foundry), do: "Default deployment"
  defp model_label(_, _), do: "Default model"

  defp model_hint(:codex, :azure_openai),
    do: "your Azure deployment name (required here or per session)"

  defp model_hint(:claude, :foundry), do: "your Foundry deployment name, e.g. claude-sonnet-5"

  defp model_hint(:claude, :bedrock),
    do: "optional: inference profile ID or ARN, e.g. us.anthropic.claude-sonnet-4-6"

  defp model_hint(:codex, :bedrock), do: "Bedrock model ID (required here or per session)"
  defp model_hint(_, _), do: "optional"

  defp credential_option(:ambient, _, :bedrock), do: "AWS credential chain (profile / SSO / env)"

  defp credential_option(:ambient, _, :foundry),
    do: "Microsoft Entra ID (Azure default credential, e.g. az login)"

  defp credential_option(:ambient, _, :vertex), do: "Google Application Default Credentials"
  defp credential_option(:ambient, _, _), do: "Ambient credentials"
  defp credential_option(:env, _, :bedrock), do: "Bedrock API key from an environment variable"
  defp credential_option(:env, _, _), do: "API key from an environment variable"
  defp credential_option(:keychain, _, :bedrock), do: "Bedrock API key in the macOS Keychain"
  defp credential_option(:aws_keys, _, _), do: "AWS access keys in the macOS Keychain (form)"
  defp credential_option(:keychain, _, _), do: "API key in the macOS Keychain"

  defp credential_label(%Profile{credential: :ambient}), do: "ambient credentials"
  defp credential_label(%Profile{credential: :env, credential_env: var}), do: "key from $#{var}"
  defp credential_label(%Profile{credential: :keychain}), do: "key in Keychain"
  defp credential_label(%Profile{credential: :aws_keys}), do: "AWS keys in Keychain"

  defp settings_summary(%Profile{settings: s}) when map_size(s) == 0, do: "no settings"

  defp settings_summary(%Profile{settings: s}),
    do: s |> Enum.sort() |> Enum.map_join("  ·  ", fn {k, v} -> "#{k} #{v}" end)
end
