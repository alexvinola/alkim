defmodule Khymeia.RuntimeCase do
  @moduledoc """
  Tests that start real sessions against the fake harness.

  Sessions share the database connection of the test (shared sandbox), so
  these tests are not async.
  """

  use ExUnit.CaseTemplate

  alias Khymeia.Runtime.Event

  using do
    quote do
      import Khymeia.RuntimeCase
      alias Khymeia.{Runtime, Session, Sessions}
      alias Khymeia.Runtime.Event
    end
  end

  setup tags do
    Khymeia.DataCase.setup_sandbox(tags)
    {:ok, workspace: workspace!()}
  end

  @doc """
  Creates an empty directory inside the configured test workspace root.
  The root is wiped once per run in test_helper.exs (not per test: harness
  processes may still be shutting down inside it when a test ends).
  """
  def workspace! do
    [root] = Application.fetch_env!(:khymeia, :workspace_roots)
    dir = Path.join(root, "ws-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  @doc """
  A workspace that is a git repository with one commit, for anything that
  needs real branches or worktrees.
  """
  def git_workspace! do
    dir = workspace!()
    git = System.find_executable("git")

    run = fn args -> System.cmd(git, ["-C", dir | args], stderr_to_stdout: true) end
    {_, 0} = run.(["init", "-q", "-b", "main", "."])
    File.write!(Path.join(dir, "README.md"), "base\n")
    {_, 0} = run.(["add", "."])

    {_, 0} =
      run.(["-c", "user.email=test@khymeia", "-c", "user.name=Test", "commit", "-qm", "base"])

    dir
  end

  @doc "Starts a fake-harness session and subscribes the test to its events."
  def start_fake!(workspace, scenario, opts \\ []) do
    attrs = %{harness: "fake", workspace: workspace, prompt: "test prompt", model: scenario}
    {:ok, session} = Khymeia.Runtime.start_session(attrs, opts)
    :ok = Khymeia.Runtime.subscribe_session(session.id)
    session
  end

  @doc """
  Waits for the first event of `type` for `session_id`, returning it plus
  every event received on the way (oldest first).
  """
  def await_event(session_id, type, timeout \\ 5_000) do
    do_await(session_id, type, timeout, [])
  end

  defp do_await(session_id, type, timeout, acc) do
    receive do
      {:session_event, %Event{session_id: ^session_id, type: ^type} = event} ->
        {event, Enum.reverse([event | acc])}

      {:session_event, %Event{session_id: ^session_id} = event} ->
        do_await(session_id, type, timeout, [event | acc])
    after
      timeout ->
        ExUnit.Assertions.flunk(
          "no #{type} event for #{session_id}; got #{inspect(Enum.map(acc, & &1.type))}"
        )
    end
  end

  @doc """
  Starts a workflow whose roles are all played by the fake harness, with the
  given scenario per role, e.g. `%{implementer: "success", auditor: "audit-pass"}`.
  Subscribes to all workflow events *before* starting, so none is missed.
  """
  def start_workflow!(workspace, scenarios, attrs \\ %{}, opts \\ []) do
    :ok = Khymeia.Workflow.subscribe_all()

    roles =
      Map.new(scenarios, fn
        {role, nil} -> {role, %{harness: "none"}}
        {role, scenario} -> {role, %{harness: "fake", model: scenario}}
      end)

    attrs = Map.merge(%{workspace: workspace, task: "Implement feature X", roles: roles}, attrs)
    {:ok, run} = Khymeia.Workflow.start(attrs, opts)
    run
  end

  @doc "Waits for workflow event `name` of run `id`; returns all events seen (oldest first)."
  def await_workflow(id, name, timeout \\ 8_000), do: do_await_workflow(id, name, timeout, [])

  defp do_await_workflow(id, name, timeout, acc) do
    receive do
      {:workflow_event, %Khymeia.Workflow.Event{workflow_id: ^id, name: ^name} = event} ->
        Enum.reverse([event | acc])

      {:workflow_event, %Khymeia.Workflow.Event{workflow_id: ^id} = event} ->
        do_await_workflow(id, name, timeout, [event | acc])
    after
      timeout ->
        ExUnit.Assertions.flunk(
          "no #{name} for workflow #{id}; got #{inspect(Enum.reverse(Enum.map(acc, & &1.name)))}"
        )
    end
  end

  @doc "Steps of a run, from the store."
  def steps(id) do
    {:ok, _run, steps} = Khymeia.Workflow.get(id)
    steps
  end

  @doc "The live session process of a step (the step must have started one)."
  def session_pid(%{session_id: id}) do
    {:ok, pid} = Khymeia.Runtime.Registry.lookup(id)
    pid
  end

  @doc "Chooses `path` through the workspace picker modal, like a user would."
  def pick_workspace(view, path) do
    import Phoenix.LiveViewTest

    view |> element("#workspace-picker-trigger") |> render_click()
    [root | _] = Khymeia.Workspace.roots()

    # Walk down from the root, one folder at a time.
    path
    |> String.replace_prefix(root, "")
    |> Path.split()
    |> Enum.reject(&(&1 == "/"))
    |> Enum.scan(root, &Path.join(&2, &1))
    |> Enum.each(fn dir ->
      view
      |> element(~s(#workspace-picker-list button[phx-value-path="#{dir}"]))
      |> render_click()
    end)

    view |> element("#workspace-picker-select") |> render_click()
  end

  @doc "True while an OS process with this pid exists."
  def os_alive?(os_pid) do
    {_, status} = System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)
    status == 0
  end

  @doc "Polls `fun` until it returns truthy (for OS-level effects we cannot subscribe to)."
  def eventually(fun, attempts \\ 50) do
    cond do
      fun.() -> :ok
      attempts == 0 -> ExUnit.Assertions.flunk("condition never became true")
      true -> Process.sleep(50) && eventually(fun, attempts - 1)
    end
  end
end
