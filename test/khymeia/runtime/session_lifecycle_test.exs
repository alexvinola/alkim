defmodule Khymeia.Runtime.SessionLifecycleTest do
  use Khymeia.RuntimeCase, async: false

  alias Khymeia.Runtime.Registry

  describe "successful turn" do
    test "streams output, then waits for input because the fake harness is resumable", %{
      workspace: ws
    } do
      session = start_fake!(ws, "success")

      {_waiting, events} = await_event(session.id, :waiting)
      types = Enum.map(events, & &1.type)

      assert :started in types
      assert Enum.any?(events, &match?(%Event{type: :output, data: %{kind: :assistant}}, &1))
      assert Enum.any?(events, &match?(%Event{type: :output, data: %{kind: :tool}}, &1))

      {:ok, live, retained} = Runtime.get_session(session.id)
      assert live.status == :waiting
      assert live.exit_code == 0
      assert live.harness_ref =~ "fake-"
      assert hd(retained).type == :input

      record = Sessions.get(session.id)
      assert record.status == :waiting
      assert record.harness_ref == live.harness_ref
    end

    test "a follow-up message resumes the harness conversation", %{workspace: ws} do
      session = start_fake!(ws, "success")
      await_event(session.id, :waiting)

      assert :ok = Runtime.send_message(session.id, "and now?")
      {_resumed, _} = await_event(session.id, :resumed)
      {_waiting, events} = await_event(session.id, :waiting)

      assert Enum.any?(events, &(&1.type == :output and &1.data.text == "You said: and now?"))
      assert {:ok, %{turns: 2}, _} = Runtime.get_session(session.id)
    end

    test "messages are rejected while a turn is running", %{workspace: ws} do
      session = start_fake!(ws, "hang")
      await_event(session.id, :started)

      assert {:error, :not_waiting} = Runtime.send_message(session.id, "hello?")
    end

    test "marking a waiting session done completes it", %{workspace: ws} do
      session = start_fake!(ws, "success")
      await_event(session.id, :waiting)

      assert :ok = Runtime.complete_session(session.id)
      await_event(session.id, :completed)
      assert Sessions.get(session.id).status == :completed
    end
  end

  test "streaming output arrives line by line, in order", %{workspace: ws} do
    session = start_fake!(ws, "stream")
    {_waiting, events} = await_event(session.id, :waiting)

    steps =
      for %Event{type: :output, data: %{kind: :stdout, text: "step " <> rest}} <- events, do: rest

    assert length(steps) == 20
    assert hd(steps) =~ "1/20"
    assert List.last(steps) =~ "20/20"
    assert events |> Enum.map(& &1.seq) |> Enum.sort() == Enum.map(events, & &1.seq)
  end

  test "a non-zero exit fails the session and keeps stderr separate", %{workspace: ws} do
    session = start_fake!(ws, "failure")
    {failed, events} = await_event(session.id, :failed)

    assert failed.data.exit_code == 3
    assert Enum.any?(events, &match?(%Event{data: %{kind: :stderr, text: "fatal: " <> _}}, &1))

    record = Sessions.get(session.id)
    assert record.status == :failed
    assert record.exit_code == 3
    assert record.completed_at
  end

  test "a turn that exceeds its timeout is killed and fails", %{workspace: ws} do
    session = start_fake!(ws, "hang", turn_timeout: 300)
    {started, _} = await_event(session.id, :started)
    {failed, _} = await_event(session.id, :failed)

    assert failed.data.error =~ "timed out"
    eventually(fn -> not os_alive?(started.data.os_pid) end)
  end

  test "stopping a running session terminates its OS process", %{workspace: ws} do
    session = start_fake!(ws, "hang")
    {started, _} = await_event(session.id, :started)
    assert os_alive?(started.data.os_pid)

    assert :ok = Runtime.stop_session(session.id)
    await_event(session.id, :stopped)

    eventually(fn -> not os_alive?(started.data.os_pid) end)
    assert Sessions.get(session.id).status == :stopped
    assert {:error, :not_running} = Runtime.stop_session(session.id)
  end

  test "stopping right after start leaves no OS processes behind", %{workspace: ws} do
    marker = "marker-#{System.unique_integer([:positive])}"

    for _ <- 1..10 do
      {:ok, session} =
        Runtime.start_session(%{harness: "fake", workspace: ws, prompt: marker, model: "hang"})

      :ok = Runtime.stop_session(session.id)
    end

    eventually(fn -> System.cmd("pgrep", ["-f", marker]) |> elem(1) == 1 end)
  end

  test "finished sessions leave the registry after the retention period", %{workspace: ws} do
    session = start_fake!(ws, "failure", retention: 100)
    await_event(session.id, :failed)

    eventually(fn -> Registry.lookup(session.id) == :error end)
    # History survives the process.
    assert {:ok, %{status: :failed}, []} = Runtime.get_session(session.id)
  end

  describe "validation" do
    test "rejects bad input before anything is started", %{workspace: ws} do
      assert {:error, {:invalid, errors}} =
               Runtime.start_session(%{
                 harness: "fake",
                 workspace: "/etc",
                 prompt: " ",
                 model: "nope"
               })

      assert Map.keys(errors) |> Enum.sort() == [:model, :prompt, :workspace]

      assert {:error, {:invalid, %{harness: _}}} =
               Runtime.start_session(%{harness: "claude", workspace: ws, prompt: "hi"})

      assert Registry.count() == 0
    end
  end
end
