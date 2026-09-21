defmodule Alkim.Terminals do
  @moduledoc """
  Public API for interactive harness sessions: the harness's own TUI, run on
  a real pseudo-terminal inside a workspace and supervised by Alkim.

  This is the lane a human drives. The CLI keeps all of its own controls —
  model, effort, permission mode, its slash commands — because it *is* the
  CLI; Alkim owns the process, the workspace and the record of what ran,
  not the interface.

  What survives, and what does not:

    * the **conversation** — persisted by the harness itself. Alkim stores
      `harness_ref` and reopens it with the CLI's own resume flag;
    * the **output** — written to disk as it happens (see
      `Alkim.Terminals.Log`), so a terminal can be reopened and read after
      Alkim itself has restarted, not just after the browser closed;
    * the **process** — a child of the runtime, so it dies with Alkim.
      An exited terminal can be read but not typed into; continuing means
      starting a new one, which asks the harness to resume the conversation.
  """

  import Ecto.Query

  alias Alkim.Harness.Discovery
  alias Alkim.Providers
  alias Alkim.Repo
  alias Alkim.Terminals.{Log, Server, Terminal}

  @pubsub Alkim.PubSub

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

    with {:ok, worktree} <- worktree(attrs),
         {:ok, workspace} <- workspace(attrs, worktree),
         {:ok, harness, profile} <- harness(attrs),
         :ok <- supports_interactive(harness),
         # Resolve the credential before recording anything, so a broken
         # provider profile does not leave a terminal that never started.
         {:ok, _provider} <- resolve(profile) do
      # A worktree lives beside its repository, so its path does not sit
      # inside the project. The terminal belongs to the project all the same.
      project =
        if worktree,
          do: Alkim.Projects.get(worktree.project_id),
          else: Alkim.Projects.ensure_for_workspace(workspace)

      Alkim.Projects.touch(project)

      terminal = %Terminal{
        id: Ecto.UUID.generate(),
        project_id: project && project.id,
        worktree_id: worktree && worktree.id,
        workflow_id: attrs.workflow,
        role: attrs.role,
        workspace: workspace,
        harness: Atom.to_string(harness.id),
        provider_profile_id: profile && profile.id,
        model: attrs.model,
        permission_mode: attrs.permission_mode,
        harness_ref: attrs.resume,
        status: :starting
      }

      with {:ok, terminal} <- insert(terminal), do: run(terminal, attrs.resume)
    end
  end

  @doc """
  Puts a process back on an existing terminal, asking the harness to continue
  the conversation it already has.

  Reopening keeps the same terminal — same id, same saved output — because a
  terminal *is* the conversation as far as the user is concerned. There is no
  separate "resume" step: opening one that is not running resumes it, and you
  type.
  """
  @spec reopen(String.t()) :: {:ok, Terminal.t()} | {:error, start_error()}
  def reopen(id) do
    case get(id) do
      nil -> {:error, {:invalid, %{terminal: "that terminal no longer exists"}}}
      terminal -> if alive?(id), do: {:ok, terminal}, else: run(terminal, resume_ref(terminal))
    end
  end

  # Claude Code names conversations by an id Alkim chose; Codex only offers
  # "the most recent one in this workspace".
  defp resume_ref(%Terminal{harness_ref: ref}) when is_binary(ref), do: ref
  defp resume_ref(_terminal), do: "last"

  @doc false
  def run(%Terminal{} = terminal, resume) do
    with {:ok, harness, profile} <- harness(%{harness: harness_choice(terminal)}),
         :ok <- supports_interactive(harness),
         {:ok, provider} <- resolve(profile),
         {:ok, launch} <- build(terminal, harness, provider, resume) do
      terminal = %{
        terminal
        | harness_ref: launch[:harness_ref] || terminal.harness_ref,
          status: :starting,
          exit_code: nil,
          completed_at: nil
      }

      save(terminal)

      case Alkim.Terminals.Supervisor.start_terminal(terminal: terminal, launch: launch) do
        {:ok, _pid} -> {:ok, terminal}
        error -> error
      end
    end
  end

  @doc """
  How to start this terminal from scratch, ignoring any conversation it was
  meant to continue. Used when resuming turns out to be impossible.
  """
  @spec fresh_launch(Terminal.t()) :: {:ok, map()} | {:error, term()}
  def fresh_launch(%Terminal{} = terminal) do
    with {:ok, harness, profile} <- harness(%{harness: harness_choice(terminal)}),
         {:ok, provider} <- resolve(profile),
         do: build(terminal, harness, provider, nil)
  end

  @doc false
  def build(%Terminal{} = terminal, harness, provider, resume) do
    harness.adapter.build_interactive(%{
      workspace: terminal.workspace,
      executable: harness.executable,
      model: terminal.model,
      permission_mode: terminal.permission_mode,
      resume: resume,
      session_id: terminal.id,
      provider: provider
    })
  end

  @doc false
  def harness_choice(%Terminal{harness: harness, provider_profile_id: nil}), do: harness
  def harness_choice(%Terminal{harness: harness, provider_profile_id: id}), do: "#{harness}@#{id}"

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
    case Alkim.Terminals.Registry.lookup(id) do
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
  # the whole point of saving it: closing Alkim must not lose the session.
  defp from_record(id) do
    case get(id) do
      nil -> :error
      terminal -> {:ok, terminal, Log.read(id)}
    end
  end

  @doc "Whether the terminal still has a live process."
  def alive?(id), do: match?({:ok, _}, Alkim.Terminals.Registry.lookup(id))

  ## Persistence

  def get(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(Terminal, uuid)
      :error -> nil
    end
  end

  @doc "All active terminals, including ones opened before the recent history window."
  def list_active do
    Terminal |> where([t], t.status != :exited) |> order_by(desc: :inserted_at) |> Repo.all()
  end

  @doc "Recently opened terminals across every project, newest first."
  def list_recent(limit \\ 20) do
    Terminal |> order_by(desc: :inserted_at) |> limit(^limit) |> Repo.all()
  end

  @doc """
  Terminals a workflow run has open, oldest first.

  Order matters here in a way it does not elsewhere: these are the agents of
  one run, and the order they were opened in is the order they entered the
  conversation.
  """
  def list_for_workflow(workflow_id) do
    Terminal |> where(workflow_id: ^workflow_id) |> order_by(asc: :inserted_at) |> Repo.all()
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

  @doc """
  Lifecycle of every terminal, for views that list them all. Output is not
  broadcast here: only the view showing a terminal should carry its bytes.
  """
  def subscribe_all, do: Phoenix.PubSub.subscribe(@pubsub, "terminals")

  @doc false
  def broadcast(id, message), do: Phoenix.PubSub.broadcast(@pubsub, topic(id), message)

  @doc false
  def broadcast_status(id, message) do
    broadcast(id, message)
    Phoenix.PubSub.broadcast(@pubsub, "terminals", message)
    Alkim.Runtime.EventBus.broadcast_nav()
  end

  defp topic(id), do: "terminal:" <> id

  ## Validation

  defp normalize(attrs) do
    get = fn key -> Map.get(attrs, key, Map.get(attrs, Atom.to_string(key))) end

    %{
      harness: get.(:harness),
      workspace: get.(:workspace),
      model: blank_to_nil(get.(:model)),
      permission_mode: blank_to_nil(get.(:permission_mode)),
      resume: blank_to_nil(get.(:resume)),
      worktree: blank_to_nil(get.(:worktree)),
      worktree_branch: blank_to_nil(get.(:worktree_branch)),
      workflow: blank_to_nil(get.(:workflow)),
      role: blank_to_nil(get.(:role))
    }
  end

  # A worktree decides the directory; otherwise the caller does.
  defp workspace(_attrs, %{path: path}), do: {:ok, path}

  defp workspace(%{workspace: path}, nil) do
    case Alkim.Workspace.validate(path) do
      {:ok, workspace} -> {:ok, workspace}
      {:error, reason} -> invalid(:workspace, Alkim.Workspace.error_message(reason))
    end
  end

  defp worktree(%{worktree: choice, workspace: workspace} = attrs) do
    project = choice == "new" && Alkim.Projects.ensure_for_workspace(workspace)
    Alkim.Worktrees.claim(choice, project || nil, nil, branch: attrs.worktree_branch)
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
    case Alkim.Harness.fetch_adapter(to_string(id)) do
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
      else: invalid(:harness, "#{name} has no interactive mode in Alkim yet")
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
    case Alkim.Terminals.Registry.lookup(id) do
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
