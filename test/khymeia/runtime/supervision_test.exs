defmodule Khymeia.Runtime.SupervisionTest do
  @moduledoc "Failures must stay contained: one session never takes down another."
  use Khymeia.RuntimeCase, async: false

  # Killing sessions on purpose logs crash reports.
  @moduletag :capture_log

  alias Khymeia.Runtime.{Registry, CrashMonitor, SessionSupervisor}

  test "a crashing session does not affect its siblings or the runtime", %{workspace: ws} do
    victim = start_fake!(ws, "hang")
    sibling = start_fake!(ws, "hang")
    {victim_started, _} = await_event(victim.id, :started)
    await_event(sibling.id, :started)

    supervisor = Process.whereis(SessionSupervisor)
    runtime = Process.whereis(Khymeia.Runtime.Supervisor)
    Runtime.subscribe_sessions()

    Process.exit(victim.pid, :kill)

    # The monitor records the crash and tells everybody.
    {failed, _} = await_event(victim.id, :failed)
    assert failed.seq == nil
    assert failed.data.error =~ "crashed"
    assert Sessions.get(victim.id).status == :failed

    # The harness process died with its port.
    eventually(fn -> not os_alive?(victim_started.data.os_pid) end)

    # Nothing else moved.
    assert Process.alive?(sibling.pid)
    assert {:ok, %{status: :running}, _} = Runtime.get_session(sibling.id)
    assert Process.whereis(SessionSupervisor) == supervisor
    assert Process.whereis(Khymeia.Runtime.Supervisor) == runtime
    eventually(fn -> Registry.lookup(victim.id) == :error end)
  end

  test "crashed sessions are not restarted (they would re-run the prompt)", %{workspace: ws} do
    session = start_fake!(ws, "hang")
    await_event(session.id, :started)
    count = length(SessionSupervisor.children())

    Process.exit(session.pid, :kill)
    await_event(session.id, :failed)

    assert length(SessionSupervisor.children()) == count - 1
  end

  test "many crashes in a row do not exhaust supervisor restart intensity", %{workspace: ws} do
    supervisor = Process.whereis(SessionSupervisor)

    for _ <- 1..6 do
      session = start_fake!(ws, "hang")
      await_event(session.id, :started)
      Process.exit(session.pid, :kill)
      await_event(session.id, :failed)
    end

    assert Process.whereis(SessionSupervisor) == supervisor
  end

  test "a restarted CrashMonitor re-watches running sessions", %{workspace: ws} do
    session = start_fake!(ws, "hang")
    await_event(session.id, :started)

    old = Process.whereis(CrashMonitor)
    Process.exit(old, :kill)
    eventually(fn -> (pid = Process.whereis(CrashMonitor)) && pid != old end)

    # The session survived the monitor's crash...
    assert Process.alive?(session.pid)

    # ...and its own crash is still recorded by the new monitor.
    Process.exit(session.pid, :kill)
    await_event(session.id, :failed)
    assert Sessions.get(session.id).status == :failed
  end

  test "Discovery crashing does not touch sessions", %{workspace: ws} do
    session = start_fake!(ws, "hang")
    await_event(session.id, :started)

    old = Process.whereis(Khymeia.Harness.Discovery)
    Process.exit(old, :kill)
    eventually(fn -> (pid = Process.whereis(Khymeia.Harness.Discovery)) && pid != old end)

    assert Process.alive?(session.pid)
    assert Enum.any?(Runtime.harnesses(), &(&1.id == :fake and &1.status == :available))
  end

  test "an orderly shutdown records the session as stopped", %{workspace: ws} do
    session = start_fake!(ws, "hang")
    {started, _} = await_event(session.id, :started)

    :ok = DynamicSupervisor.terminate_child(SessionSupervisor, session.pid)

    assert Sessions.get(session.id).status == :stopped
    eventually(fn -> not os_alive?(started.data.os_pid) end)
  end
end
