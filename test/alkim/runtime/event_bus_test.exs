defmodule Alkim.Runtime.EventBusTest do
  use ExUnit.Case, async: true

  alias Alkim.Runtime.{Event, EventBus}

  setup do
    {:ok, id: Ecto.UUID.generate()}
  end

  test "every event goes to the session topic", %{id: id} do
    EventBus.subscribe_session(id)
    event = Event.new(id, 1, :output, %{kind: :stdout, text: "hi"})

    EventBus.publish(event)
    assert_receive {:session_event, ^event}
  end

  test "only lifecycle events go to the global sessions topic", %{id: id} do
    EventBus.subscribe_sessions()

    EventBus.publish(Event.new(id, 1, :output, %{kind: :stdout, text: "noise"}))
    EventBus.publish(Event.new(id, 2, :completed, %{exit_code: 0}))

    assert_receive {:session_event, %Event{session_id: ^id, type: :completed}}
    refute_receive {:session_event, %Event{session_id: ^id, type: :output}}, 50
  end

  test "events have dotted public names and roles", %{id: id} do
    assert Event.name(Event.new(id, 1, :started)) == "session.started"
    assert Event.role(Event.new(id, 1, :input, %{text: "x"})) == :user
    assert Event.role(Event.new(id, 1, :output, %{})) == :harness
    assert Event.role(Event.new(id, 1, :failed)) == :runtime
  end
end
