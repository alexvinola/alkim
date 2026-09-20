defmodule KhymeiaWeb.SessionLive do
  @moduledoc """
  One session: metadata, controls and its activity, streamed in real time.

  On mount we subscribe first and fetch the snapshot second, then drop any
  broadcast event whose `seq` the snapshot already contained. That ordering
  guarantees no event is lost or shown twice.
  """

  use KhymeiaWeb, :live_view

  import KhymeiaWeb.SessionComponents

  alias Khymeia.{Harness, Runtime, Session}
  alias Khymeia.Runtime.Event

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: Runtime.subscribe_session(id)

    case Runtime.get_session(id) do
      {:ok, session, events} ->
        {:ok,
         socket
         |> assign(
           page_title: "#{Session.title(session)} · Khymeia",
           session: session,
           capabilities: capabilities(session.harness),
           harness_name: harness_name(session.harness),
           last_seq: events |> List.last(%{seq: 0}) |> Map.get(:seq),
           has_events: events != [],
           project: Khymeia.Projects.get(session.project_id),
           message: ""
         )
         |> stream_configure(:events, dom_id: &dom_id/1)
         |> stream(:events, events)}

      :error ->
        {:ok,
         socket
         |> put_flash(:error, "Session not found")
         |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("stop", _params, socket) do
    socket.assigns.session.id |> Runtime.stop_session() |> reply(socket)
  end

  def handle_event("complete", _params, socket) do
    socket.assigns.session.id |> Runtime.complete_session() |> reply(socket)
  end

  def handle_event("message_change", %{"message" => message}, socket) do
    {:noreply, assign(socket, message: message)}
  end

  def handle_event("send", %{"message" => message}, socket) do
    case Runtime.send_message(socket.assigns.session.id, message) do
      :ok -> {:noreply, assign(socket, message: "")}
      error -> reply(error, socket)
    end
  end

  @impl true
  def handle_info({:session_event, %Event{seq: seq}}, socket)
      when is_integer(seq) and seq <= socket.assigns.last_seq,
      do: {:noreply, socket}

  def handle_info({:session_event, %Event{} = event}, socket) do
    socket =
      socket
      |> stream_insert(:events, event)
      |> assign(last_seq: event.seq || socket.assigns.last_seq, has_events: true)

    socket = if Event.lifecycle?(event), do: refresh_session(socket), else: socket
    {:noreply, socket}
  end

  defp refresh_session(socket) do
    case Runtime.get_session(socket.assigns.session.id) do
      {:ok, session, _events} -> assign(socket, session: session)
      :error -> socket
    end
  end

  defp reply(:ok, socket), do: {:noreply, refresh_session(socket)}

  defp reply({:error, reason}, socket),
    do: {:noreply, put_flash(socket, :error, error_message(reason))}

  defp error_message(:not_found), do: "The session process is no longer running."
  defp error_message(:not_waiting), do: "The harness is still working on the current turn."
  defp error_message(:unsupported), do: "This harness does not support follow-up messages."
  defp error_message(:empty_message), do: "Write a message first."
  defp error_message(reason), do: "Error: #{inspect(reason)}"

  defp capabilities(harness) do
    case Harness.fetch_adapter(harness) do
      {:ok, adapter} -> adapter.capabilities()
      :error -> %Harness.Capabilities{stop: false}
    end
  end

  defp dom_id(%Event{seq: nil, type: type}), do: "ev-final-#{type}"
  defp dom_id(%Event{seq: seq}), do: "ev-#{seq}"

  defp live?(session), do: not is_nil(session.pid) or not Session.terminal?(session)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} nav={@nav} active={:sessions} project={@project}>
      <div class="k-section-head">
        <div style="min-width:0">
          <h1 class="k-h1 k-truncate">{Session.title(@session)}</h1>
          <span class="k-mono k-faint">{@session.id}</span>
          <.link
            :if={workflow_id = @session.metadata["workflow_id"]}
            navigate={~p"/workflows/#{workflow_id}"}
            class="k-hint k-link"
            style="margin-left:.5rem"
          >
            {@session.metadata["role"]} in workflow →
          </.link>
        </div>
        <div style="display:flex;gap:.5rem;flex:none">
          <button
            :if={@session.status == :waiting}
            class="k-btn"
            phx-click="complete"
            id="complete-session"
          >
            Mark done
          </button>
          <button
            :if={@capabilities.stop and @session.status in [:starting, :running, :waiting]}
            class="k-btn k-btn-danger"
            phx-click="stop"
            id="stop-session"
            data-confirm={
              @session.status == :running &&
                "Stop this session? The harness process will be terminated."
            }
          >
            Stop
          </button>
        </div>
      </div>

      <section class="k-section">
        <div class="k-panel">
          <dl class="k-meta" id="session-meta">
            <div>
              <dt>Status</dt><dd id="session-status"><.status status={@session.status} /></dd>
            </div>
            <div>
              <dt>Harness</dt><dd>{@harness_name}</dd>
            </div>
            <div>
              <dt>Workspace</dt>
              <dd class="k-mono">{short_path(@session.workspace)}</dd>
            </div>
            <div :if={@session.metadata["provider"]}>
              <dt>Provider</dt><dd>{@session.metadata["provider"]}</dd>
            </div>
            <div>
              <dt>Model</dt><dd>{@session.model || "Default / configured in harness"}</dd>
            </div>
            <div :if={@session.permission_mode}>
              <dt>Permissions</dt><dd>{@session.permission_mode}</dd>
            </div>
            <div>
              <dt>Started</dt><dd>{datetime(@session.started_at)}</dd>
            </div>
            <div>
              <dt>Duration</dt>
              <dd>
                <.elapsed
                  id="session-elapsed"
                  since={@session.started_at}
                  until={@session.completed_at}
                />
              </dd>
            </div>
            <div>
              <dt>Turns</dt><dd>{@session.turns}</dd>
            </div>
            <div :if={@session.exit_code}>
              <dt>Exit code</dt><dd class="k-mono">{@session.exit_code}</dd>
            </div>
            <div :if={@session.os_pid}>
              <dt>OS pid</dt><dd class="k-mono">{@session.os_pid}</dd>
            </div>
            <div :if={@session.harness_ref}>
              <dt>Harness session</dt>
              <dd class="k-mono k-truncate" title={@session.harness_ref}>{@session.harness_ref}</dd>
            </div>
          </dl>
          <div :if={@session.error} class="k-banner k-banner-error" style="margin:0 1rem 1rem">
            {@session.error}
          </div>
        </div>
      </section>

      <section class="k-section">
        <div class="k-section-head">
          <h2 class="k-h2">Activity</h2>
        </div>
        <div class="k-panel">
          <div :if={not @has_events} class="k-empty">
            <%= if live?(@session) do %>
              Waiting for output…
            <% else %>
              Activity is kept in memory only while the session process is alive.
              <div class="k-prompt" style="text-align:left;margin-top:.75rem">{@session.prompt}</div>
            <% end %>
          </div>
          <div id="activity" class="k-activity" phx-update="stream" phx-hook="FollowTail">
            <.event
              :for={{dom_id, event} <- @streams.events}
              id={dom_id}
              event={event}
              harness_name={@harness_name}
            />
          </div>

          <.composer session={@session} capabilities={@capabilities} message={@message} />
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :session, Session, required: true
  attr :capabilities, :any, required: true
  attr :message, :string, required: true

  defp composer(assigns) do
    ~H"""
    <form
      :if={@capabilities.resume and not Session.terminal?(@session)}
      class="k-composer"
      id="composer"
      phx-submit="send"
      phx-change="message_change"
    >
      <textarea
        name="message"
        class="k-textarea"
        placeholder={
          if @session.status == :waiting,
            do: "Send a follow-up message…",
            else: "You can reply when the current turn finishes."
        }
        disabled={@session.status != :waiting}
        phx-hook="SubmitOnMetaEnter"
        id="message-input"
      >{@message}</textarea>
      <div class="k-composer-actions">
        <span class="k-hint">Resumes the harness conversation with a new turn.</span>
        <button type="submit" class="k-btn k-btn-primary" disabled={@session.status != :waiting}>
          Send message
        </button>
      </div>
    </form>
    <div :if={not @capabilities.resume and not Session.terminal?(@session)} class="k-composer k-hint">
      This harness does not support follow-up messages.
    </div>
    """
  end
end
