defmodule Khymeia.Harness.Executable do
  @moduledoc """
  Locates harness executables and builds the `PATH` harnesses run with.

  When Khymeia runs as a daemon (`brew services`, launchd, systemd) it does not
  inherit the user's interactive shell `PATH`, so CLIs installed in
  `~/.local/bin` or `/opt/homebrew/bin` would be invisible. We therefore search
  the inherited `PATH` plus a list of conventional install locations, plus any
  directories in `KHYMEIA_EXTRA_PATH`.

  A specific binary can always be pinned with `KHYMEIA_<ID>_BIN`, e.g.
  `KHYMEIA_CLAUDE_BIN=/opt/tools/claude`.
  """

  @conventional_dirs [
    "~/.local/bin",
    "/opt/homebrew/bin",
    "/usr/local/bin",
    "~/.npm-global/bin",
    "~/.bun/bin",
    "~/.volta/bin",
    "~/.cargo/bin"
  ]

  @doc "Finds `name` for harness `id`, honouring `KHYMEIA_<ID>_BIN`."
  @spec find(atom(), String.t()) :: {:ok, String.t()} | :not_found
  def find(id, name) do
    case System.get_env("KHYMEIA_#{id |> Atom.to_string() |> String.upcase()}_BIN") do
      nil -> find_in_path(name)
      "" -> find_in_path(name)
      pinned -> if executable?(pinned), do: {:ok, pinned}, else: :not_found
    end
  end

  @doc "Searches `search_path/0` for an executable file called `name`."
  @spec find_in_path(String.t()) :: {:ok, String.t()} | :not_found
  def find_in_path(name) do
    search_path()
    |> String.split(":", trim: true)
    |> Enum.map(&Path.join(&1, name))
    |> Enum.find(&executable?/1)
    |> case do
      nil -> :not_found
      path -> {:ok, path}
    end
  end

  @doc "The inherited `PATH` extended with extra and conventional directories."
  @spec search_path() :: String.t()
  def search_path do
    inherited = String.split(System.get_env("PATH", ""), ":", trim: true)
    extra = String.split(System.get_env("KHYMEIA_EXTRA_PATH", ""), ":", trim: true)
    conventional = Enum.map(@conventional_dirs, &Path.expand/1)

    (inherited ++ extra ++ conventional)
    |> Enum.uniq()
    |> Enum.join(":")
  end

  @doc """
  Runs `executable args` with a timeout and the extended `PATH`. Returns the
  output only on exit status 0. Never raises. stderr is merged into the
  output only with `stderr: :merge`; otherwise it is not captured.
  """
  @spec run(String.t(), [String.t()], keyword()) :: {:ok, String.t()} | :error
  def run(executable, args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    merge? = Keyword.get(opts, :stderr) == :merge

    task =
      Task.async(fn ->
        System.cmd(executable, args,
          stderr_to_stdout: merge?,
          env: [{"PATH", search_path()}]
        )
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> {:ok, output}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  @doc "First line of `executable --version`, or `nil`."
  @spec version(String.t()) :: String.t() | nil
  def version(executable) do
    case run(executable, ["--version"], stderr: :merge) do
      {:ok, output} -> output |> String.split("\n", trim: true) |> List.first()
      :error -> nil
    end
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end
end
