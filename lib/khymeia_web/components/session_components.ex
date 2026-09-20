defmodule KhymeiaWeb.SessionComponents do
  @moduledoc """
  Function components shared by the session views.

  `event/1` renders one runtime event by *role*: user input and assistant
  messages as conversation turns, everything else as compact log lines.
  The same component is meant to render a future multi-harness
  conversation, where events from several sessions are merged by time.
  """

  use Phoenix.Component

  import KhymeiaWeb.CoreComponents, only: [icon: 1]

  alias Khymeia.Runtime.Event

  use Phoenix.VerifiedRoutes, endpoint: KhymeiaWeb.Endpoint, router: KhymeiaWeb.Router

  attr :active, :atom, required: true

  @doc "Chat / Workflow switch shown on both creation pages."
  def mode_tabs(assigns) do
    ~H"""
    <nav class="k-tabs" aria-label="Mode">
      <.link navigate={~p"/sessions/new"} aria-current={@active == :chat && "page"}>Chat</.link>
      <.link navigate={~p"/workflows/new"} aria-current={@active == :workflow && "page"}>Workflow</.link>
    </nav>
    """
  end

  attr :status, :atom, required: true

  def status(assigns) do
    ~H"""
    <span class={"k-status k-status-#{@status}"}>
      <span class="k-dot"></span>{@status}
    </span>
    """
  end

  attr :name, :string, required: true
  attr :value, :string, default: nil
  attr :worktrees, :list, default: []
  attr :error, :string, default: nil
  attr :hint, :string, default: nil
  attr :unavailable, :string, default: nil, doc: "why a new worktree is not possible here"

  @doc """
  Where the work runs: the project folder, a fresh worktree, or one that
  already exists. Offered wherever work is started, in the same words.
  """
  def worktree_field(assigns) do
    ~H"""
    <div class="k-field">
      <label class="k-label" for={@name}>Isolation</label>
      <select id={@name} name={@name} class="k-select">
        <option value="" selected={@value in [nil, ""]}>Work in the project folder</option>
        <option value="new" selected={@value == "new"} disabled={@unavailable != nil}>
          New git worktree and branch
        </option>
        <option :for={w <- @worktrees} value={w.id} selected={w.id == @value}>
          Existing: {w.branch}
        </option>
      </select>
      <span :if={@error} class="k-error">{@error}</span>
      <span :if={@unavailable} class="k-hint k-warn">No new worktree here: {@unavailable}</span>
      <span :if={is_nil(@unavailable)} class="k-hint">
        {@hint ||
          "A worktree gives the agent its own directory and branch, so it cannot disturb what you are working on. Khymeia never merges it."}
      </span>
    </div>
    """
  end

  attr :entry, :map, required: true, doc: "a `KhymeiaWeb.WorkEntry`"

  @doc "One piece of work — a session or a workflow run — as a card."
  def work_card(assigns) do
    ~H"""
    <.link navigate={@entry.path} id={"card-#{@entry.id}"} class="k-card">
      <div class="k-card-head">
        <.status status={@entry.status} />
        <.icon :if={kind_icon(@entry.kind)} name={kind_icon(@entry.kind)} class="size-3.5 k-faint" />
      </div>
      <p class="k-card-title">{@entry.title}</p>
      <div class="k-card-meta">
        <span class="k-tag">{@entry.label}</span>
        <span :if={@entry.tag} class="k-tag">{@entry.tag}</span>
        <span :if={@entry.detail} class="k-mono k-faint k-truncate">{@entry.detail}</span>
      </div>
      <div class="k-card-foot">
        <%= if @entry.active? do %>
          <.elapsed id={"card-elapsed-#{@entry.id}"} since={@entry.started_at} />
        <% else %>
          <span class="k-mono k-faint">
            {format_duration(@entry.started_at, @entry.completed_at)}
          </span>
        <% end %>
      </div>
    </.link>
    """
  end

  attr :entry, :map, required: true
  attr :id, :string, default: nil

  @doc "The same work as a compact row, for history lists."
  def work_row(assigns) do
    ~H"""
    <.link navigate={@entry.path} id={@id || "row-#{@entry.id}"} class="k-row k-row-session">
      <span>
        {@entry.label}
        <span :if={@entry.tag} class="k-tag">{@entry.tag}</span>
      </span>
      <span class="k-truncate">{@entry.title}</span>
      <span class="k-mono k-faint k-truncate k-hide-sm">{short_path(@entry.workspace)}</span>
      <.status status={@entry.status} />
      <span class="k-hide-sm" style="text-align:right">
        <%= if @entry.active? do %>
          <.elapsed id={"row-elapsed-#{@entry.id}"} since={@entry.started_at} />
        <% else %>
          <span class="k-mono k-muted">
            {format_duration(@entry.started_at, @entry.completed_at)}
          </span>
        <% end %>
      </span>
    </.link>
    """
  end

  defp kind_icon(:workflow), do: "hero-square-3-stack-3d"
  defp kind_icon(:terminal), do: "hero-command-line"
  defp kind_icon(_), do: nil

  attr :id, :string, required: true
  attr :since, :any, required: true
  attr :until, :any, default: nil

  def elapsed(assigns) do
    ~H"""
    <span
      :if={@since}
      id={@id}
      class="k-mono k-muted"
      phx-hook="Elapsed"
      data-since={DateTime.to_iso8601(@since)}
      data-until={@until && DateTime.to_iso8601(@until)}
    >
      {format_duration(@since, @until)}
    </span>
    """
  end

  attr :id, :string, required: true
  attr :event, Event, required: true
  attr :harness_name, :string, required: true

  def event(%{event: %Event{type: :input}} = assigns) do
    ~H"""
    <div id={@id} class="k-ev k-msg k-msg-user">
      <span class="k-ev-time">{time(@event.at)}</span>
      <div class="k-ev-body"><span class="k-who">You</span>{@event.data.text}</div>
    </div>
    """
  end

  def event(%{event: %Event{type: :output, data: %{kind: :assistant}}} = assigns) do
    ~H"""
    <div id={@id} class="k-ev k-msg">
      <span class="k-ev-time">{time(@event.at)}</span>
      <div class="k-ev-body"><span class="k-who">{@harness_name}</span>{@event.data.text}</div>
    </div>
    """
  end

  def event(%{event: %Event{type: :output}} = assigns) do
    ~H"""
    <div id={@id} class={"k-ev k-log k-log-#{@event.data.kind}"}>
      <span class="k-ev-time">{time(@event.at)}</span>
      <div class="k-ev-body">{@event.data.text}</div>
    </div>
    """
  end

  def event(assigns) do
    ~H"""
    <div id={@id} class={"k-ev k-life k-life-#{@event.type}"}>
      <span class="k-ev-time">{time(@event.at)}</span>
      <div class="k-ev-body">{Event.name(@event)}{lifecycle_detail(@event)}</div>
    </div>
    """
  end

  defp lifecycle_detail(%Event{type: :started, data: %{os_pid: pid}}) when not is_nil(pid),
    do: " · pid #{pid}"

  defp lifecycle_detail(%Event{type: :resumed, data: data}), do: " · turn #{data[:turn]}"

  defp lifecycle_detail(%Event{type: :failed, data: data}),
    do: " · " <> (data[:error] || "exit #{data[:exit_code]}")

  defp lifecycle_detail(%Event{type: :completed, data: %{exit_code: code}}) when not is_nil(code),
    do: " · exit #{code}"

  defp lifecycle_detail(_), do: ""

  ## Formatting helpers

  def harness_name(id) do
    case Khymeia.Harness.fetch_adapter(id) do
      {:ok, adapter} -> adapter.name()
      :error -> id |> to_string() |> String.capitalize()
    end
  end

  def short_path(nil), do: ""

  def short_path(path) do
    home = System.user_home() || ""

    if home != "" and String.starts_with?(path, home),
      do: "~" <> String.trim_leading(path, home),
      else: path
  end

  def time(%DateTime{} = at), do: at |> local() |> Calendar.strftime("%H:%M:%S")
  def time(_), do: ""

  def datetime(nil), do: "—"
  def datetime(%DateTime{} = at), do: at |> local() |> Calendar.strftime("%Y-%m-%d %H:%M:%S")

  def format_duration(nil, _), do: ""

  def format_duration(since, until) do
    total = max(DateTime.diff(until || DateTime.utc_now(), since), 0)
    {h, m, s} = {div(total, 3600), div(rem(total, 3600), 60), rem(total, 60)}
    pad = &String.pad_leading(Integer.to_string(&1), 2, "0")
    if h > 0, do: "#{h}:#{pad.(m)}:#{pad.(s)}", else: "#{pad.(m)}:#{pad.(s)}"
  end

  # Timestamps are stored in UTC. Khymeia is local-first, so the machine's
  # local time is the user's local time.
  defp local(%DateTime{} = at) do
    at
    |> DateTime.to_naive()
    |> NaiveDateTime.to_erl()
    |> :calendar.universal_time_to_local_time()
    |> NaiveDateTime.from_erl!()
  end
end
