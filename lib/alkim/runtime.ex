defmodule Alkim.Runtime do
  @moduledoc """
  Public API of the Alkim runtime.

  The web UI (and any future CLI or API) goes through this module only. It
  never spawns harness processes itself: every execution is a supervised
  `Alkim.Runtime.SessionServer`.
  """

  alias Alkim.{Harness, Session, Sessions, Workspace}
  alias Alkim.Harness.Discovery
  alias Alkim.Runtime.{EventBus, Registry, SessionServer, SessionSupervisor}

  # Wide enough for Bedrock inference-profile ARNs and Foundry deployment names.
  @model_format ~r/\A[A-Za-z0-9][A-Za-z0-9._:\/@\[\]-]{0,254}\z/
  @max_prompt 100_000

  @type start_error ::
          {:invalid, %{atom() => String.t()}}
          | {:error, :not_installed | :unknown_harness | term()}

  ## Harnesses

  defdelegate harnesses, to: Discovery, as: :list
  defdelegate refresh_harnesses, to: Discovery, as: :refresh

  ## Sessions

  @doc """
  Validates the request, records the session and starts its process.

  `attrs` (string or atom keys): `harness`, `workspace`, `prompt`, and
  optionally `model` and `permission_mode`. `harness` may name a provider
  profile as `"claude@<profile id>"` (see `Alkim.Providers`). Validation errors come back as
  `{:error, {:invalid, %{field => message}}}`.

  Options: `:owner` (a pid that receives every event and whose exit stops
  the session), `:metadata`, `:turn_timeout`, `:retention`.
  """
  @spec start_session(map(), keyword()) :: {:ok, Session.t()} | {:error, start_error()}
  def start_session(attrs, opts \\ []) do
    with {:ok, harness, params} <- prepare(attrs) do
      {metadata, opts} = Keyword.pop(opts, :metadata, %{})

      metadata =
        case params.profile do
          nil ->
            metadata

          p ->
            Map.merge(metadata, %{
              "provider_profile_id" => p.id,
              "provider" => Alkim.Providers.Profile.label(p)
            })
        end

      project = Alkim.Projects.ensure_for_workspace(params.workspace)

      with {:ok, worktree} <-
             Alkim.Worktrees.claim(params.worktree, project, title(params.prompt)) do
        # An isolated session runs in the worktree, not in the project folder.
        workspace = if worktree, do: worktree.path, else: params.workspace

        project =
          if worktree, do: Alkim.Projects.get(worktree.project_id) || project, else: project

        Alkim.Projects.touch(project)

        session = %Session{
          id: Ecto.UUID.generate(),
          harness: harness.id,
          workspace: workspace,
          project_id: project && project.id,
          worktree_id: worktree && worktree.id,
          prompt: params.prompt,
          model: params.model,
          permission_mode: params.permission_mode,
          metadata: metadata
        }

        server_opts =
          [
            session: session,
            adapter: harness.adapter,
            executable: harness.executable,
            provider_profile: params.profile && params.profile.id
          ] ++ opts

        with {:ok, _record} <- Sessions.create(session) do
          case SessionSupervisor.start_session(server_opts) do
            {:ok, pid} ->
              {:ok, %{session | pid: pid}}

            {:error, reason} ->
              error = "could not start session: #{inspect(reason)}"

              Sessions.sync(%{
                session
                | status: :failed,
                  error: error,
                  completed_at: DateTime.utc_now()
              })

              {:error, reason}
          end
        end
      end
    end
  end

  # The first words of the prompt, so an isolated session's branch is
  # recognisable in `git branch` rather than being a random string.
  defp title(prompt) do
    prompt |> String.split(~r/\s+/, trim: true) |> Enum.take(5) |> Enum.join(" ")
  end

  @doc """
  Validates a session request without starting anything. Returns the
  normalized parameters (canonical workspace, trimmed prompt).
  """
  @spec validate_request(map()) :: {:ok, map()} | {:error, start_error()}
  def validate_request(attrs) do
    with {:ok, _harness, params} <- prepare(attrs), do: {:ok, params}
  end

  defp prepare(attrs) do
    attrs = normalize(attrs)

    {harness_id, profile_id} = Alkim.Providers.parse_choice(attrs.harness)

    with {:ok, harness} <- fetch_harness(harness_id),
         {:ok, profile} <- fetch_profile(profile_id, harness),
         attrs = apply_profile_defaults(attrs, profile),
         {:ok, params} <- validate(attrs, harness),
         :ok <- require_model(params, profile) do
      {:ok, harness, Map.put(params, :profile, profile)}
    end
  end

  @doc "Stops a running or waiting session. Its harness process is terminated."
  def stop_session(id), do: with_session(id, &SessionServer.stop/1)

  @doc "Marks a `waiting` session as completed (no further messages)."
  def complete_session(id), do: with_session(id, &SessionServer.complete/1)

  @doc "Sends a follow-up message to a `waiting` session, if its harness supports it."
  def send_message(id, text) when is_binary(text) do
    case String.trim(text) do
      "" -> {:error, :empty_message}
      text -> with_session(id, &SessionServer.send_message(&1, text))
    end
  end

  @doc """
  Returns `{session, events}`. Live sessions answer from their process; for
  sessions whose process is gone, the persisted record is returned with no
  events.
  """
  @spec get_session(String.t()) :: {:ok, Session.t(), [Alkim.Runtime.Event.t()]} | :error
  def get_session(id) do
    with {:ok, pid} <- Registry.lookup(id),
         {:ok, {session, events}} <- safe_call(fn -> SessionServer.snapshot(pid) end) do
      {:ok, session, events}
    else
      _ ->
        case Sessions.get(id) do
          nil -> :error
          record -> {:ok, Sessions.to_session(record), []}
        end
    end
  end

  @doc """
  Sessions whose process is alive, as lightweight summaries read from the
  registry (no process is called).
  """
  def list_live do
    Registry.list()
    |> Enum.map(fn {id, pid, summary} -> Map.merge(summary, %{id: id, pid: pid}) end)
    |> Enum.sort_by(&started_at/1, {:desc, DateTime})
  end

  # A session that has not started yet was created a moment ago, so it
  # belongs at the top rather than crashing the sort with a nil.
  defp started_at(%{started_at: nil}), do: DateTime.utc_now()
  defp started_at(%{started_at: at}), do: at

  @doc """
  Distinct workspaces used recently by sessions and workflows, newest first,
  keeping only those that are still valid workspaces.
  """
  def recent_workspaces(limit \\ 8) do
    import Ecto.Query

    sessions =
      from(s in Alkim.Sessions.SessionRecord,
        group_by: s.workspace,
        select: {s.workspace, max(s.inserted_at)}
      )

    workflows =
      from(w in Alkim.Workflow.Run,
        group_by: w.workspace,
        select: {w.workspace, max(w.inserted_at)}
      )

    (Alkim.Repo.all(sessions) ++ Alkim.Repo.all(workflows))
    |> Enum.sort_by(fn {_, at} -> to_string(at) end, :desc)
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.filter(&match?({:ok, _}, Workspace.validate(&1)))
    |> Enum.take(limit)
  end

  @doc "Recently recorded sessions, newest first."
  def list_recent(limit \\ 20), do: Enum.map(Sessions.list_recent(limit), &Sessions.to_session/1)

  @doc "Recently recorded sessions of one project, newest first."
  def list_recent_for_project(project_id, limit \\ 20),
    do: Enum.map(Sessions.list_for_project(project_id, limit), &Sessions.to_session/1)

  defdelegate subscribe_sessions, to: EventBus
  defdelegate subscribe_session(id), to: EventBus
  defdelegate unsubscribe_session(id), to: EventBus
  defdelegate subscribe_harnesses, to: EventBus

  ## Helpers

  defp with_session(id, fun) do
    case Registry.lookup(id) do
      {:ok, pid} ->
        case safe_call(fn -> fun.(pid) end) do
          {:ok, result} -> result
          error -> error
        end

      :error ->
        {:error, :not_found}
    end
  end

  # The session may exit between lookup and call.
  defp safe_call(fun) do
    {:ok, fun.()}
  catch
    :exit, _ -> {:error, :not_found}
  end

  defp normalize(attrs) do
    get = fn key -> Map.get(attrs, key, Map.get(attrs, Atom.to_string(key))) end

    %{
      harness: get.(:harness),
      workspace: get.(:workspace),
      prompt: get.(:prompt),
      model: blank_to_nil(get.(:model)),
      permission_mode: blank_to_nil(get.(:permission_mode)),
      worktree: blank_to_nil(get.(:worktree))
    }
  end

  defp fetch_harness(nil), do: {:error, {:invalid, %{harness: "choose a harness"}}}

  defp fetch_harness(id) do
    case Harness.fetch_adapter(to_string(id)) do
      {:ok, adapter} ->
        case Discovery.fetch_available(adapter.id()) do
          {:ok, harness} -> {:ok, harness}
          {:error, _} -> {:error, {:invalid, %{harness: "#{adapter.name()} is not installed"}}}
        end

      :error ->
        {:error, {:invalid, %{harness: "unknown or unsupported harness"}}}
    end
  end

  defp fetch_profile(nil, _harness), do: {:ok, nil}

  defp fetch_profile(id, harness) do
    kinds =
      if function_exported?(harness.adapter, :provider_kinds, 0),
        do: harness.adapter.provider_kinds(),
        else: []

    case Alkim.Providers.get(id) do
      %{harness: h, kind: kind} = profile when h == harness.id ->
        if kind in kinds,
          do: {:ok, profile},
          else: {:error, {:invalid, %{harness: "#{harness.name} cannot use this provider"}}}

      _ ->
        {:error, {:invalid, %{harness: "unknown provider profile"}}}
    end
  end

  defp apply_profile_defaults(attrs, %{default_model: model}) when is_binary(model),
    do: %{attrs | model: attrs.model || model}

  defp apply_profile_defaults(attrs, _), do: attrs

  defp require_model(%{model: nil}, %Alkim.Providers.Profile{} = profile) do
    if Alkim.Providers.Profile.requires_model?(profile),
      do:
        {:error,
         {:invalid,
          %{
            model:
              "#{Alkim.Providers.Profile.kind_label(profile.kind)} needs a model or deployment name"
          }}},
      else: :ok
  end

  defp require_model(_params, _profile), do: :ok

  defp validate(attrs, %{capabilities: capabilities}) do
    errors =
      %{}
      |> check(:workspace, validate_workspace(attrs.workspace))
      |> check(:prompt, validate_prompt(attrs.prompt))
      |> check(:model, validate_model(attrs.model, capabilities))
      |> check(:permission_mode, validate_permission(attrs.permission_mode, capabilities))

    if errors == %{} do
      {:ok,
       %{
         attrs
         | workspace: elem(Workspace.validate(attrs.workspace), 1),
           prompt: String.trim(attrs.prompt)
       }}
    else
      {:error, {:invalid, errors}}
    end
  end

  defp check(errors, _field, :ok), do: errors
  defp check(errors, field, {:error, message}), do: Map.put(errors, field, message)

  defp validate_workspace(path) do
    case Workspace.validate(path) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, Workspace.error_message(reason)}
    end
  end

  defp validate_prompt(prompt) when is_binary(prompt) do
    cond do
      String.trim(prompt) == "" -> {:error, "write a prompt"}
      byte_size(prompt) > @max_prompt -> {:error, "prompt is too long"}
      true -> :ok
    end
  end

  defp validate_prompt(_), do: {:error, "write a prompt"}

  defp validate_model(nil, _caps), do: :ok

  defp validate_model(_model, %{model_selection: false}),
    do: {:error, "this harness does not accept a model"}

  defp validate_model(model, %{models: models}) when is_list(models) do
    if model in models, do: :ok, else: {:error, "unknown model"}
  end

  defp validate_model(model, _caps) do
    if Regex.match?(@model_format, model), do: :ok, else: {:error, "invalid model name"}
  end

  defp validate_permission(nil, _caps), do: :ok

  defp validate_permission(mode, %{permission_modes: modes}) do
    if Enum.any?(modes, fn {value, _label} -> value == mode end),
      do: :ok,
      else: {:error, "unsupported permission mode"}
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp blank_to_nil(value), do: to_string(value)
end
