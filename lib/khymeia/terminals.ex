defmodule Khymeia.Terminals do
  @moduledoc """
  Public API for interactive harness sessions: the harness's own TUI, run on
  a real pseudo-terminal inside a workspace and supervised by Khymeia.

  This is the lane a human drives. The CLI keeps all of its own controls —
  model, effort, permission mode, its slash commands — because it *is* the
  CLI; Khymeia owns the process, the workspace and the record of what ran,
  not the interface.

  What survives, and what does not:

    * the **conversation** — persisted by the harness itself. Khymeia stores
      `harness_ref` and reopens it with the CLI's own resume flag;
    * the **output** — written to disk as it happens (see
      `Khymeia.Terminals.Log`), so a terminal can be reopened and read after
      Khymeia itself has restarted, not just after the browser closed;
    * the **process** — a child of the runtime, so it dies with Khymeia.
      An exited terminal can be read but not typed into; continuing means
      starting a new one, which asks the harness to resume the conversation.
  """

  import Ecto.Query

  alias Khymeia.Harness.Discovery
  alias Khymeia.Providers
  alias Khymeia.Repo
  alias Khymeia.Terminals.{Log, Server, Terminal}

  @pubsub Khymeia.PubSub

  @type start_error :: {:invalid, %{atom() => String.t()}} | {:error, term()}

  @doc """
  Starts an interactive terminal.

  `attrs` (string or atom keys): `harness` (optionally `"claude@<profile>"`),
  `workspace`, and optionally `model`, `permission_mode` and `resume` — the
  harness reference of a conversation to continue, or `"last"` where the CLI
  only offers "most recent".
  """
  @spec start(map()) :: {:ok, Terminal.t()} | {:error, start_error()}
  def start(attrs) do
    attrs = normalize(attrs)

    with {:ok, workspace} <- workspace(attrs),
         {:ok, harness, profile} <- harness(attrs),
         :ok <- supports_interactive(harness),
         {:ok, provider} <- resolve(profile) do
      project = Khymeia.Projects.ensure_for_workspace(workspace)
      Khymeia.Projects.touch(project)

      terminal = %Terminal{
        id: Ecto.UUID.generate(),
        project_id: project && project.id,
        workspace: workspace,
        harness: Atom.to_string(harness.id),
        provider_profile_id: profile && profile.id,
        model: attrs.model,
        permission_mode: attrs.permission_mode,
        # Claude Code lets Khymeia choose the conversation id up front; the
        # adapter says so by echoing it back in the launch.
        harness_ref: attrs.resume,
        status: :starting
      }

      session = %{
        workspace: workspace,
        executable: harness.executable,
        model: attrs.model,
        permission_mode: attrs.permission_mode,
        resume: attrs.resume,
        session_id: terminal.id,
        provider: provider
      }

      with {:ok, launch} <- harness.adapter.build_interactive(session),
           terminal = %{terminal | harness_ref: launch[:harness_ref] || terminal.harness_ref},
           {:ok, terminal} <- insert(terminal),
           {:ok, _pid} <-
             Khymeia.Terminals.Supervisor.start_terminal(terminal: terminal, launch: launch) do
        {:ok, terminal}
      end
    end
  end

  @doc "Sends raw keystrokes. The bytes are not interpreted."
  def send_keys(id, data) when is_binary(data), do: with_terminal(id, &Server.send_keys(&1, data))

  @doc "Reports the viewer's window size so the TUI lays itself out to fit."
  def resize(id, rows, cols), do: with_terminal(id, &Server.resize(&1, rows, cols))

  @doc "Asks the harness to exit."
  def stop(id), do: with_terminal(id, &Server.stop/1)

  @doc """
  Everything a client needs to display the terminal: its record and the
  scrollback so far. A terminal whose process is gone answers from the
  database with an empty scrollback.
  """
  @spec attach(String.t()) :: {:ok, Terminal.t(), binary()} | :error
  def attach(id) do
    case Khymeia.Terminals.Registry.lookup(id) do
      {:ok, pid} ->
        try do
          {terminal, scrollback} = Server.snapshot(pid)
          {:ok, terminal, scrollback}
        catch
          :exit, _ -> from_record(id)
        end

      :error ->
        from_record(id)
    end
  end

  # A terminal whose process is gone still has its output on disk, which is
  # the whole point of saving it: closing Khymeia must not lose the session.
  defp from_record(id) do
    case get(id) do
      nil -> :error
      terminal -> {:ok, terminal, Log.read(id)}
    end
  end

  @doc "Whether the terminal still has a live process."
  def alive?(id), do: match?({:ok, _}, Khymeia.Terminals.Registry.lookup(id))

  ## Persistence

  def get(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(Terminal, uuid)
      :error -> nil
    end
  end

  @doc "Terminals of a project, live ones first."
  def list_for_project(project_id, limit \\ 20) do
    Terminal
    |> where(project_id: ^project_id)
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.sort_by(&(not Terminal.live?(&1)))
  end

  @doc false
  def save(%Terminal{} = terminal) do
    terminal
    |> Terminal.changeset()
    |> Ecto.Changeset.force_change(:updated_at, DateTime.utc_now())
    |> Repo.insert(on_conflict: {:replace_all_except, [:id, :inserted_at]}, conflict_target: :id)
  rescue
    error ->
      require Logger
      Logger.error("could not persist terminal #{terminal.id}: #{inspect(error)}")
      {:error, error}
  end

  @doc """
  Forgets a terminal: its record and everything it printed. The only way to
  remove saved output, so it is offered wherever a terminal is listed.
  """
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(id) do
    with :ok <- stop_if_alive(id) do
      Log.delete(id)

      case get(id) do
        nil -> :ok
        terminal -> with {:ok, _} <- Repo.delete(terminal), do: :ok
      end
    end
  end

  defp stop_if_alive(id) do
    if alive?(id) do
      stop(id)
      # Give the harness the same grace the helper does before dropping state.
      Process.sleep(200)
      :ok
    else
      :ok
    end
  end

  @doc """
  Called at boot: a terminal from a previous run has no process to attach
  to, so it is closed rather than left looking alive.
  """
  def close_interrupted do
    now = DateTime.utc_now()

    Terminal
    |> where([t], t.status in [:starting, :running])
    |> Repo.update_all(set: [status: :exited, completed_at: now, updated_at: now])
  end

  ## Events

  def subscribe(id), do: Phoenix.PubSub.subscribe(@pubsub, topic(id))
  def unsubscribe(id), do: Phoenix.PubSub.unsubscribe(@pubsub, topic(id))

  @doc false
  def broadcast(id, message), do: Phoenix.PubSub.broadcast(@pubsub, topic(id), message)

  defp topic(id), do: "terminal:" <> id

  ## Validation

  defp normalize(attrs) do
    get = fn key -> Map.get(attrs, key, Map.get(attrs, Atom.to_string(key))) end

    %{
      harness: get.(:harness),
      workspace: get.(:workspace),
      model: blank_to_nil(get.(:model)),
      permission_mode: blank_to_nil(get.(:permission_mode)),
      resume: blank_to_nil(get.(:resume))
    }
  end

  defp workspace(%{workspace: path}) do
    case Khymeia.Workspace.validate(path) do
      {:ok, workspace} -> {:ok, workspace}
      {:error, reason} -> invalid(:workspace, Khymeia.Workspace.error_message(reason))
    end
  end

  defp harness(%{harness: choice}) do
    {harness_id, profile_id} = Providers.parse_choice(choice)

    with {:ok, adapter} <- fetch_adapter(harness_id),
         {:ok, harness} <- fetch_available(adapter),
         {:ok, profile} <- fetch_profile(profile_id, harness) do
      {:ok, harness, profile}
    end
  end

  defp fetch_adapter(nil), do: invalid(:harness, "choose a harness")

  defp fetch_adapter(id) do
    case Khymeia.Harness.fetch_adapter(to_string(id)) do
      {:ok, adapter} -> {:ok, adapter}
      :error -> invalid(:harness, "unknown or unsupported harness")
    end
  end

  defp fetch_available(adapter) do
    case Discovery.fetch_available(adapter.id()) do
      {:ok, harness} -> {:ok, harness}
      {:error, _} -> invalid(:harness, "#{adapter.name()} is not installed")
    end
  end

  defp fetch_profile(nil, _harness), do: {:ok, nil}

  defp fetch_profile(id, harness) do
    case Providers.get(id) do
      %{harness: h} = profile when h == harness.id -> {:ok, profile}
      _ -> invalid(:harness, "unknown provider profile")
    end
  end

  # An adapter that cannot say how to start its TUI does not get one invented.
  defp supports_interactive(%{adapter: adapter, name: name}) do
    if function_exported?(adapter, :build_interactive, 1),
      do: :ok,
      else: invalid(:harness, "#{name} has no interactive mode in Khymeia yet")
  end

  defp resolve(nil), do: {:ok, nil}

  defp resolve(profile) do
    case Providers.resolve(profile.id) do
      {:ok, provider} -> {:ok, provider}
      {:error, reason} -> invalid(:harness, to_string(reason))
    end
  end

  defp insert(terminal) do
    case terminal |> Terminal.changeset() |> Repo.insert() do
      {:ok, terminal} -> {:ok, terminal}
      {:error, changeset} -> {:error, {:invalid, errors(changeset)}}
    end
  end

  defp errors(changeset) do
    Map.new(changeset.errors, fn {field, {message, _}} -> {field, message} end)
  end

  defp invalid(field, message), do: {:error, {:invalid, %{field => message}}}

  defp with_terminal(id, fun) do
    case Khymeia.Terminals.Registry.lookup(id) do
      {:ok, pid} ->
        try do
          fun.(pid)
          :ok
        catch
          :exit, _ -> {:error, :not_found}
        end

      :error ->
        {:error, :not_found}
    end
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
