defmodule AlkimWeb.SessionComponents do
  @moduledoc """
  Function components shared by the session views.

  `event/1` renders one runtime event by *role*: user input and assistant
  messages as conversation turns, everything else as compact log lines.
  The same component is meant to render a future multi-harness
  conversation, where events from several sessions are merged by time.
  """

  use Phoenix.Component

  import AlkimWeb.CoreComponents, only: [icon: 1]

  alias Alkim.Runtime.Event

  use Phoenix.VerifiedRoutes, endpoint: AlkimWeb.Endpoint, router: AlkimWeb.Router

  attr :active, :atom, required: true

  @doc "Chat / Workflow switch shown on both creation pages."
  def mode_tabs(assigns) do
    ~H"""
    <nav class="a-tabs" aria-label="Mode">
      <.link navigate={~p"/sessions/new"} aria-current={@active == :chat && "page"}>Chat</.link>
      <.link navigate={~p"/workflows/new"} aria-current={@active == :workflow && "page"}>Workflow</.link>
    </nav>
    """
  end

  attr :status, :atom, required: true

  def status(assigns) do
    ~H"""
    <span class={"a-status a-status-#{@status}"}>
      <span class="a-dot"></span>{@status}
    </span>
    """
  end

  attr :name, :string, required: true
  attr :value, :string, default: nil
  attr :worktrees, :list, default: []
  attr :branch_name, :string, default: nil, doc: "form field holding the branch choice"
  attr :branch, :string, default: nil
  attr :branches, :list, default: []
  attr :error, :string, default: nil
  attr :hint, :string, default: nil
  attr :unavailable, :string, default: nil, doc: "why a new worktree is not possible here"

  @doc """
  Where the work runs: the project folder, a fresh worktree, or one that
  already exists. Offered wherever work is started, in the same words.

  A fresh worktree asks a second question — *on which branch* — because the
  two decisions are independent: a new branch cut from HEAD is the common
  case, but continuing an existing branch in its own directory is the other
  half of the same feature.
  """
  def worktree_field(assigns) do
    ~H"""
    <div class="a-field">
      <label class="a-label" for={@name}>Isolation</label>
      <select id={@name} name={@name} class="a-select">
        <option value="" selected={@value in [nil, ""]}>Work in the project folder</option>
        <option value="new" selected={@value == "new"} disabled={@unavailable != nil}>
          New git worktree
        </option>
        <option :for={w <- @worktrees} value={w.id} selected={w.id == @value}>
          Existing: {w.branch}
        </option>
      </select>
      <span :if={@error} class="a-error">{@error}</span>
      <span :if={@unavailable} class="a-hint a-warn">No new worktree here: {@unavailable}</span>
      <span :if={is_nil(@unavailable)} class="a-hint">
        {@hint ||
          "A worktree gives the agent its own directory and branch, so it cannot disturb what you are working on. Alkim never merges it."}
      </span>

      <div :if={@branch_name && @value == "new"} class="a-field" style="margin-top:.5rem">
        <label class="a-label" for={@branch_name}>Branch</label>
        <select id={@branch_name} name={@branch_name} class="a-select">
          <option value="new" selected={@branch in [nil, "", "new"]}>
            New branch, cut from HEAD
          </option>
          <option
            :for={b <- @branches}
            value={b.name}
            selected={b.name == @branch}
            disabled={b.checked_out}
          >
            {b.name}{if b.checked_out, do: " — in use"}
          </option>
        </select>
        <span class="a-hint">
          An existing branch keeps its own history: the worktree starts where that
          branch already is, not where you are standing.
        </span>
      </div>
    </div>
    """
  end

  attr :entry, :map, required: true, doc: "a `AlkimWeb.WorkEntry`"

  @doc "One piece of work — a session or a workflow run — as a card."
  def work_card(assigns) do
    ~H"""
    <.link navigate={@entry.path} id={"card-#{@entry.id}"} class="a-card">
      <div class="a-card-head">
        <.status status={@entry.status} />
        <.icon name={kind_icon(@entry.kind)} class="size-3.5 a-faint" />
      </div>
      <p class="a-card-title">{@entry.title}</p>
      <div class="a-card-meta">
        <span class="a-tag">{@entry.label}</span>
        <span :if={@entry.children > 0} class="a-tag">{@entry.children} agent(s)</span>
        <span :if={@entry.tag} class="a-tag">{@entry.tag}</span>
        <span :if={@entry.detail} class="a-mono a-faint a-truncate">{@entry.detail}</span>
      </div>
      <div class="a-card-foot">
        <%= if @entry.active? do %>
          <.elapsed id={"card-elapsed-#{@entry.id}"} since={@entry.started_at} />
        <% else %>
          <span class="a-mono a-faint">
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
    <.link navigate={@entry.path} id={@id || "row-#{@entry.id}"} class="a-row a-row-session">
      <span>
        {@entry.label}
        <span :if={@entry.children > 0} class="a-tag">{@entry.children} agent(s)</span>
        <span :if={@entry.tag} class="a-tag">{@entry.tag}</span>
      </span>
      <span class="a-truncate">{@entry.title}</span>
      <span class="a-mono a-faint a-truncate a-hide-sm">{short_path(@entry.workspace)}</span>
      <.status status={@entry.status} />
      <span class="a-hide-sm" style="text-align:right">
        <%= if @entry.active? do %>
          <.elapsed id={"row-elapsed-#{@entry.id}"} since={@entry.started_at} />
        <% else %>
          <span class="a-mono a-muted">
            {format_duration(@entry.started_at, @entry.completed_at)}
          </span>
        <% end %>
      </span>
    </.link>
    """
  end

  @doc "The icon that tells a terminal from a session or a workflow run."
  def kind_icon(:workflow), do: "hero-square-3-stack-3d"
  def kind_icon(:terminal), do: "hero-command-line"
  def kind_icon(_), do: "hero-chat-bubble-left-right"

  attr :id, :string, required: true
  attr :since, :any, required: true
  attr :until, :any, default: nil

  def elapsed(assigns) do
    ~H"""
    <span
      :if={@since}
      id={@id}
      class="a-mono a-muted"
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
    <div id={@id} class="a-ev a-msg a-msg-user">
      <span class="a-ev-time">{time(@event.at)}</span>
      <div class="a-ev-body"><span class="a-who">You</span>{@event.data.text}</div>
    </div>
    """
  end

  def event(%{event: %Event{type: :output, data: %{kind: :assistant}}} = assigns) do
    ~H"""
    <div id={@id} class="a-ev a-msg">
      <span class="a-ev-time">{time(@event.at)}</span>
      <div class="a-ev-body"><span class="a-who">{@harness_name}</span>{@event.data.text}</div>
    </div>
    """
  end

  def event(%{event: %Event{type: :output}} = assigns) do
    ~H"""
    <div id={@id} class={"a-ev a-log a-log-#{@event.data.kind}"}>
      <span class="a-ev-time">{time(@event.at)}</span>
      <div class="a-ev-body">{@event.data.text}</div>
    </div>
    """
  end

  def event(assigns) do
    ~H"""
    <div id={@id} class={"a-ev a-life a-life-#{@event.type}"}>
      <span class="a-ev-time">{time(@event.at)}</span>
      <div class="a-ev-body">{Event.name(@event)}{lifecycle_detail(@event)}</div>
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
    case Alkim.Harness.fetch_adapter(id) do
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

  # Timestamps are stored in UTC. Alkim is local-first, so the machine's
  # local time is the user's local time.
  defp local(%DateTime{} = at) do
    at
    |> DateTime.to_naive()
    |> NaiveDateTime.to_erl()
    |> :calendar.universal_time_to_local_time()
    |> NaiveDateTime.from_erl!()
  end
end
