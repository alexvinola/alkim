defmodule AlkimWeb.WorkEntry do
  @moduledoc """
  Sessions and workflow runs flattened into the few fields the lists, cards
  and sidebar actually render, so the views do not branch on which kind of
  work they are showing.
  """

  use Phoenix.VerifiedRoutes, endpoint: AlkimWeb.Endpoint, router: AlkimWeb.Router

  alias Alkim.{Session, Workflow}
  alias Alkim.Terminals.Terminal

  @type t :: %{
          id: String.t(),
          kind: :session | :workflow | :terminal,
          title: String.t(),
          status: atom(),
          active?: boolean(),
          label: String.t(),
          tag: String.t() | nil,
          detail: String.t() | nil,
          workspace: String.t() | nil,
          path: String.t(),
          owner_id: String.t() | nil,
          children: non_neg_integer(),
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
      owner_id: Map.get(session, :metadata, %{})["workflow_id"],
      children: 0,
      started_at: Map.get(session, :started_at),
      completed_at: Map.get(session, :completed_at)
    }
  end

  @doc """
  A terminal. Its title is the harness, because the interesting thing about
  an interactive session is which agent is on the other end — there is no
  prompt to summarise.
  """
  @spec from_terminal(Terminal.t()) :: t()
  def from_terminal(terminal) do
    %{
      id: terminal.id,
      kind: :terminal,
      title: harness_name(terminal.harness),
      status: if(Terminal.live?(terminal), do: :running, else: :completed),
      active?: Terminal.live?(terminal),
      label: "Terminal",
      tag: terminal.model,
      detail: nil,
      workspace: terminal.workspace,
      path: ~p"/projects/#{terminal.project_id}/terminal?#{[t: terminal.id]}",
      owner_id: nil,
      children: 0,
      started_at: terminal.started_at || terminal.inserted_at,
      completed_at: terminal.completed_at
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
      owner_id: nil,
      children: 0,
      started_at: run.started_at,
      completed_at: run.completed_at
    }
  end

  @doc """
  Folds the agents a workflow is running into the workflow itself.

  A run with three roles would otherwise appear four times in one list: the
  run, plus a card for each agent it started. Work that belongs to a parent
  is shown by its parent, and the parent says how many are inside. An agent
  whose run is not in this list keeps its own entry, so nothing disappears.
  """
  @spec group([t()]) :: [t()]
  def group(entries) do
    owners = MapSet.new(entries, & &1.id)
    {owned, loose} = Enum.split_with(entries, &(&1.owner_id && &1.owner_id in owners))
    counts = Enum.frequencies_by(owned, & &1.owner_id)

    Enum.map(loose, fn entry ->
      case counts[entry.id] do
        nil -> entry
        n -> %{entry | children: n}
      end
    end)
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
    case Alkim.Harness.fetch_adapter(id) do
      {:ok, adapter} -> adapter.name()
      :error -> id |> to_string() |> String.capitalize()
    end
  end
end
