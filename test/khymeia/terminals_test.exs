defmodule Khymeia.TerminalsTest do
  use Khymeia.RuntimeCase, async: false

  import Khymeia.RuntimeCase, only: [workspace!: 0, eventually: 1]

  alias Khymeia.Terminals

  defp open!(workspace, attrs \\ %{}) do
    {:ok, terminal} =
      Terminals.start(Map.merge(%{"harness" => "fake", "workspace" => workspace}, attrs))

    :ok = Terminals.subscribe(terminal.id)
    terminal
  end

  # Collects broadcast output until `match` shows up, so tests never sleep.
  defp await_output(id, match, acc \\ "") do
    receive do
      {:terminal_output, ^id, chunk} ->
        acc = acc <> chunk
        if String.contains?(acc, match), do: acc, else: await_output(id, match, acc)

      {:terminal_status, _} ->
        await_output(id, match, acc)
    after
      5_000 -> flunk("never saw #{inspect(match)}; got: #{inspect(acc)}")
    end
  end

  test "the harness runs on a real terminal, sized by the client" do
    terminal = open!(workspace!())

    assert await_output(terminal.id, "interactive on") =~ "interactive on tty"

    Terminals.resize(terminal.id, 40, 132)
    Terminals.send_keys(terminal.id, "size\n")

    assert await_output(terminal.id, "40 132") =~ "40 132"
  end

  test "keystrokes reach the harness and its output comes back" do
    terminal = open!(workspace!())
    await_output(terminal.id, "fake>")

    Terminals.send_keys(terminal.id, "hello\n")
    assert await_output(terminal.id, "echo:") =~ "echo: hello"
  end

  test "the scrollback is replayed when a client re-attaches" do
    terminal = open!(workspace!())
    Terminals.send_keys(terminal.id, "marker-one\n")
    await_output(terminal.id, "echo: marker-one")

    {:ok, attached, scrollback} = Terminals.attach(terminal.id)

    assert attached.id == terminal.id
    assert scrollback =~ "echo: marker-one"
  end

  test "exiting the harness closes the terminal and records the status" do
    terminal = open!(workspace!())
    await_output(terminal.id, "fake>")

    Terminals.send_keys(terminal.id, "exit\n")

    eventually(fn -> Terminals.get(terminal.id).status == :exited end)
    assert Terminals.get(terminal.id).exit_code == 0
    refute Terminals.alive?(terminal.id)
  end

  test "stopping a terminal kills the harness, leaving no process behind" do
    # The marker rides along in argv so the check finds this terminal's own
    # process and not one belonging to a test running beside it.
    marker = "orphan-probe-#{System.unique_integer([:positive])}"
    terminal = open!(workspace!(), %{"resume" => marker})
    await_output(terminal.id, "fake>")

    assert running?(marker)

    Terminals.stop(terminal.id)

    eventually(fn -> not Terminals.alive?(terminal.id) end)
    eventually(fn -> Terminals.get(terminal.id).status == :exited end)
    eventually(fn -> not running?(marker) end)
  end

  defp running?(marker) do
    {out, _} = System.cmd("pgrep", ["-f", marker], stderr_to_stdout: true)
    String.trim(out) != ""
  end

  test "a terminal belongs to the project of its workspace" do
    workspace = workspace!()
    terminal = open!(workspace)

    project = Khymeia.Projects.get_by_path(workspace)
    assert terminal.project_id == project.id
    assert [%{id: id}] = Terminals.list_for_project(project.id)
    assert id == terminal.id
  end

  test "output is saved to disk and survives the terminal's process" do
    terminal = open!(workspace!())
    await_output(terminal.id, "fake>")
    Terminals.send_keys(terminal.id, "saved-line\n")
    await_output(terminal.id, "echo: saved-line")

    Terminals.stop(terminal.id)
    eventually(fn -> not Terminals.alive?(terminal.id) end)

    # Nothing is running now, so this can only come from the log on disk.
    {:ok, _terminal, scrollback} = Terminals.attach(terminal.id)
    assert scrollback =~ "echo: saved-line"
    assert File.regular?(Khymeia.Terminals.Log.path(terminal.id))
  end

  test "saved output is readable only by its owner" do
    terminal = open!(workspace!())
    await_output(terminal.id, "fake>")

    %{mode: mode} = File.stat!(Khymeia.Terminals.Log.path(terminal.id))
    assert Bitwise.band(mode, 0o077) == 0
  end

  test "deleting a terminal forgets its record and everything it printed" do
    workspace = workspace!()
    terminal = open!(workspace)
    await_output(terminal.id, "fake>")
    path = Khymeia.Terminals.Log.path(terminal.id)

    assert :ok = Terminals.delete(terminal.id)

    assert Terminals.get(terminal.id) == nil
    refute File.exists?(path)
    refute Terminals.alive?(terminal.id)
  end

  test "a conversation that cannot be resumed still leaves a usable terminal" do
    workspace = workspace!()

    {:ok, terminal} =
      Terminals.start(%{
        "harness" => "fake",
        "workspace" => workspace,
        "resume" => "missing-#{System.unique_integer([:positive])}"
      })

    :ok = Terminals.subscribe(terminal.id)

    # The harness refuses and exits; Khymeia says so and starts a fresh one
    # rather than handing back a terminal that died on arrival.
    assert await_output(terminal.id, "could not continue") =~ "[khymeia]"
    assert await_output(terminal.id, "fake>") =~ "interactive on tty"

    eventually(fn -> Terminals.alive?(terminal.id) end)
    assert Terminals.get(terminal.id).status == :running
  end

  test "a workspace outside the allowed roots is refused" do
    assert {:error, {:invalid, %{workspace: _}}} =
             Terminals.start(%{"harness" => "fake", "workspace" => "/etc"})
  end

  # Khymeia only offers a terminal for harnesses whose interactive mode was
  # verified; a merely detected CLI gets no invented command line.
  test "a harness Khymeia has no adapter for is refused" do
    assert {:error, {:invalid, %{harness: message}}} =
             Terminals.start(%{"harness" => "kiro", "workspace" => workspace!()})

    assert message =~ "unknown or unsupported harness"
  end
end
