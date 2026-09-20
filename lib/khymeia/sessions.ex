defmodule Khymeia.Sessions do
  @moduledoc """
  Persistence context for session history (SQLite via Ecto).

  Only session processes and the runtime write here; the web layer reads
  through `Khymeia.Runtime`.
  """

  import Ecto.Query
  require Logger

  alias Khymeia.Repo
  alias Khymeia.Session
  alias Khymeia.Sessions.SessionRecord

  @doc "Inserts the record for a session that is about to start."
  def create(%Session{} = session) do
    session
    |> Map.from_struct()
    |> Map.update!(:harness, &Atom.to_string/1)
    |> SessionRecord.create_changeset()
    |> Repo.insert()
  end

  @doc """
  Mirrors the persistent fields of a runtime snapshot. Failures are logged,
  not raised: losing a history row must never take a live session down.
  """
  def sync(%Session{} = session) do
    attrs =
      Map.take(
        session,
        ~w(status harness_ref turns exit_code error metadata started_at completed_at)a
      )

    with %SessionRecord{} = record <- Repo.get(SessionRecord, session.id),
         {:ok, record} <- record |> SessionRecord.update_changeset(attrs) |> Repo.update() do
      {:ok, record}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> log_failure(session.id, reason)
    end
  rescue
    error -> log_failure(session.id, error)
  end

  def get(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(SessionRecord, uuid)
      :error -> nil
    end
  end

  def list_recent(limit \\ 20) do
    SessionRecord
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Recently recorded sessions of one project, newest first."
  def list_for_project(project_id, limit \\ 20) do
    SessionRecord
    |> where(project_id: ^project_id)
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Called at boot: sessions left `starting`, `running` or `waiting` by a
  previous run can no longer be attached to, so they are marked failed.
  """
  def fail_interrupted do
    now = DateTime.utc_now()

    SessionRecord
    |> where([s], s.status in [:starting, :running, :waiting])
    |> Repo.update_all(
      set: [
        status: :failed,
        error: "interrupted: Khymeia stopped while the session was active",
        completed_at: now,
        updated_at: now
      ]
    )
  end

  @doc "Converts a record into a runtime snapshot (for sessions no longer alive)."
  def to_session(%SessionRecord{} = record) do
    %Session{
      id: record.id,
      harness: String.to_existing_atom(record.harness),
      workspace: record.workspace,
      project_id: record.project_id,
      worktree_id: record.worktree_id,
      prompt: record.prompt,
      model: record.model,
      permission_mode: record.permission_mode,
      status: record.status,
      harness_ref: record.harness_ref,
      turns: record.turns,
      exit_code: record.exit_code,
      error: record.error,
      started_at: record.started_at,
      completed_at: record.completed_at,
      metadata: record.metadata
    }
  end

  defp log_failure(id, reason) do
    Logger.error("could not persist session #{id}: #{inspect(reason)}")
    {:error, reason}
  end
end
