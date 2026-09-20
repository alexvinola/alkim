defmodule KhymeiaWeb.WorkEntry do
  @moduledoc """
  Sessions and workflow runs flattened into the few fields the lists, cards
  and sidebar actually render, so the views do not branch on which kind of
  work they are showing.
  """

  use Phoenix.VerifiedRoutes, endpoint: KhymeiaWeb.Endpoint, router: KhymeiaWeb.Router

  alias Khymeia.{Session, Workflow}

  @type t :: %{
          id: String.t(),
          kind: :session | :workflow,
          title: String.t(),
          status: atom(),
          active?: boolean(),
          label: String.t(),
          tag: String.t() | nil,
          detail: String.t() | nil,
          workspace: String.t() | nil,
          path: String.t(),
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil
        }

  @spec from_session(map()) :: t()
  def from_session(session) do
    %{
      id: session.id,
      kind: :session,
      title: Session.title(session),
      status: session.status,
      active?: not Session.terminal?(session.status),
      label: harness_name(session.harness),
      tag: Map.get(session, :metadata, %{})["role"],
      detail: Map.get(session, :model),
      workspace: Map.get(session, :workspace),
      path: ~p"/sessions/#{session.id}",
      started_at: Map.get(session, :started_at),
      completed_at: Map.get(session, :completed_at)
    }
  end

  @spec from_run(Workflow.Run.t()) :: t()
  def from_run(run) do
    %{
      id: run.id,
      kind: :workflow,
      title: run.title || run.name,
      status: run.status,
      active?: Workflow.Run.active?(run),
      label: "Workflow",
      tag: run.current_step,
      detail: step_detail(run),
      workspace: run.workspace,
      path: ~p"/workflows/#{run.id}",
      started_at: run.started_at,
      completed_at: run.completed_at
    }
  end

  @doc "Active work first, then the rest, each newest first."
  @spec sort([t()]) :: [t()]
  def sort(entries) do
    Enum.sort_by(entries, &{not &1.active?, negated_time(&1)})
  end

  defp negated_time(%{started_at: nil}), do: 0
  defp negated_time(%{started_at: at}), do: -DateTime.to_unix(at, :microsecond)

  defp step_detail(%{current_step: nil}), do: nil
  defp step_detail(%{current_step: step, iteration: 0}), do: step
  defp step_detail(%{current_step: step, iteration: n}), do: "#{step} · it. #{n}"

  defp harness_name(id) do
    case Khymeia.Harness.fetch_adapter(id) do
      {:ok, adapter} -> adapter.name()
      :error -> id |> to_string() |> String.capitalize()
    end
  end
end
