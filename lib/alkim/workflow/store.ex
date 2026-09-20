defmodule Alkim.Workflow.Store do
  @moduledoc "Persistence of workflow runs and their steps."

  import Ecto.Query
  require Logger

  alias Alkim.Repo
  alias Alkim.Workflow.{Run, Step}

  def insert_run(%Run{} = run), do: run |> Run.changeset() |> Repo.insert()

  @doc "Upserts a run or step struct. Failures are logged, never raised."
  def save(%Run{} = run), do: upsert(run, &Run.changeset/1)
  def save(%Step{} = step), do: upsert(step, &Step.changeset/1)

  defp upsert(struct, changeset) do
    struct
    |> Map.put(:updated_at, nil)
    |> changeset.()
    |> Ecto.Changeset.force_change(:updated_at, DateTime.utc_now())
    |> Repo.insert(on_conflict: {:replace_all_except, [:id, :inserted_at]}, conflict_target: :id)
  rescue
    error ->
      Logger.error(
        "could not persist #{inspect(struct.__struct__)} #{struct.id}: #{inspect(error)}"
      )

      {:error, error}
  end

  def get_run(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(Run, uuid)
      :error -> nil
    end
  end

  def steps(workflow_id) do
    Step
    |> where(workflow_id: ^workflow_id)
    |> order_by([s], asc: s.started_at, asc: s.inserted_at)
    |> Repo.all()
  end

  def list_recent(limit \\ 20) do
    Run |> order_by(desc: :inserted_at) |> limit(^limit) |> Repo.all()
  end

  def list_for_project(project_id, limit \\ 20) do
    Run
    |> where(project_id: ^project_id)
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Called at boot: runs left active by a previous Alkim process cannot be
  re-attached to (their harness processes are gone), so they are marked
  failed, and so are their running steps.
  """
  def fail_interrupted do
    now = DateTime.utc_now()
    active = [:pending, :running, :waiting, :auditing, :fixing]
    ids = Run |> where([r], r.status in ^active) |> select([r], r.id) |> Repo.all()

    Step
    |> where([s], s.workflow_id in ^ids and s.status in [:running, :waiting])
    |> Repo.update_all(
      set: [status: :failed, error: "interrupted", completed_at: now, updated_at: now]
    )

    Run
    |> where([r], r.id in ^ids)
    |> Repo.update_all(
      set: [
        status: :failed,
        error: "interrupted: Alkim stopped while the workflow was active",
        completed_at: now,
        updated_at: now
      ]
    )
  end
end
