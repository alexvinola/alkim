defmodule Khymeia.Runtime.EventBus do
  @moduledoc """
  The only place that knows topic names. Built on `Phoenix.PubSub`, so
  subscribers (LiveViews today; a CLI bridge or other sessions tomorrow)
  never poll.

  Topics:

    * `"sessions"` — lifecycle events of every session (dashboard);
    * `"session:<id>"` — every event of one session (detail view);
    * `"harnesses"` — discovery results changed;
    * `"nav"` — anything that changes the shell's project/session lists;
    * `"workflows"` / `"workflow:<id>"` — workflow events.

  Messages delivered to subscribers:

    * `{:session_event, %Khymeia.Runtime.Event{}}`
    * `{:harnesses, [harness]}`
    * `{:workflow_event, %Khymeia.Workflow.Event{}}`
    * `:nav_changed`

  The `"nav"` topic carries no payload on purpose: it exists so the shell can
  refresh its lists without subscribing to every session, which would deliver
  other sessions' events to views that must only see their own.
  """

  alias Khymeia.Runtime.Event

  @pubsub Khymeia.PubSub

  def subscribe_sessions, do: Phoenix.PubSub.subscribe(@pubsub, "sessions")
  def subscribe_session(id), do: Phoenix.PubSub.subscribe(@pubsub, "session:" <> id)
  def unsubscribe_session(id), do: Phoenix.PubSub.unsubscribe(@pubsub, "session:" <> id)
  def subscribe_harnesses, do: Phoenix.PubSub.subscribe(@pubsub, "harnesses")
  def subscribe_nav, do: Phoenix.PubSub.subscribe(@pubsub, "nav")

  @doc "Tells the shell its project/session lists may have changed."
  def broadcast_nav, do: Phoenix.PubSub.broadcast(@pubsub, "nav", :nav_changed)

  @spec publish(Event.t()) :: :ok
  def publish(%Event{} = event) do
    message = {:session_event, event}
    Phoenix.PubSub.broadcast(@pubsub, "session:" <> event.session_id, message)

    if Event.lifecycle?(event) do
      Phoenix.PubSub.broadcast(@pubsub, "sessions", message)
      broadcast_nav()
    end

    :ok
  end

  def subscribe_workflows, do: Phoenix.PubSub.subscribe(@pubsub, "workflows")
  def subscribe_workflow(id), do: Phoenix.PubSub.subscribe(@pubsub, "workflow:" <> id)

  def publish_workflow(%Khymeia.Workflow.Event{} = event) do
    message = {:workflow_event, event}
    Phoenix.PubSub.broadcast(@pubsub, "workflow:" <> event.workflow_id, message)
    Phoenix.PubSub.broadcast(@pubsub, "workflows", message)
    broadcast_nav()
    :ok
  end

  def broadcast_harnesses(harnesses),
    do: Phoenix.PubSub.broadcast(@pubsub, "harnesses", {:harnesses, harnesses})
end
