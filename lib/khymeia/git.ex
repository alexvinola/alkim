defmodule Khymeia.Git do
  @moduledoc """
  What git can tell reliably about a workspace.

  Paths are relative to the workspace, which may be a subdirectory of a
  repository. A *snapshot* maps every path git reports as modified/untracked to the hash
  of its current content (or `:deleted`). Comparing two snapshots yields the
  files a step changed — including files that were already dirty before the
  workflow started but were modified again. Outside a git repository every
  function returns `:unavailable`, and callers record "unknown" rather than
  inventing a list.
  """

  alias Khymeia.Harness.Executable

  @type snapshot :: %{String.t() => String.t() | :deleted}

  @spec snapshot(String.t()) :: snapshot() | :unavailable
  def snapshot(workspace) do
    with {:ok, git} <- git(),
         {:ok, prefix} <- Executable.run(git, ["-C", workspace, "rev-parse", "--show-prefix"]),
         {:ok, out} <-
           Executable.run(git, [
             "-C",
             workspace,
             "status",
             "--porcelain=v1",
             "-z",
             "--untracked-files=all",
             "--",
             "."
           ]) do
      # Status paths are relative to the repository root; the workspace may
      # be a subdirectory of it. Keep everything workspace-relative.
      prefix = String.trim(prefix)
      paths = out |> parse_porcelain() |> Enum.map(&String.replace_prefix(&1, prefix, ""))
      {present, deleted} = Enum.split_with(paths, &File.regular?(Path.join(workspace, &1)))

      hashes =
        case present do
          [] -> []
          _ -> hash(git, workspace, present)
        end

      Map.new(Enum.zip(present, hashes) ++ Enum.map(deleted, &{&1, :deleted}))
    else
      _ -> :unavailable
    end
  end

  @type status :: %{
          branch: String.t() | nil,
          upstream: String.t() | nil,
          ahead: non_neg_integer() | nil,
          behind: non_neg_integer() | nil,
          changes: [%{code: String.t(), path: String.t()}],
          commits: [%{hash: String.t(), subject: String.t(), author: String.t(), at: String.t()}]
        }

  @doc """
  What the workspace looks like right now: branch, distance from its
  upstream, uncommitted changes and the last commits. `:unavailable` outside
  a git repository — the UI says so rather than showing an empty repo.
  """
  @spec status(String.t()) :: status() | :unavailable
  def status(workspace) do
    with {:ok, git} <- git(),
         {:ok, _} <- run(git, workspace, ["rev-parse", "--is-inside-work-tree"]) do
      {ahead, behind} = tracking(git, workspace)

      %{
        branch: one_line(run(git, workspace, ["rev-parse", "--abbrev-ref", "HEAD"])),
        upstream:
          one_line(
            run(git, workspace, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"])
          ),
        ahead: ahead,
        behind: behind,
        changes: changes(git, workspace),
        commits: commits(git, workspace)
      }
    else
      _ -> :unavailable
    end
  end

  defp tracking(git, workspace) do
    case run(git, workspace, ["rev-list", "--left-right", "--count", "@{u}...HEAD"]) do
      {:ok, out} ->
        case out |> String.trim() |> String.split(~r/\s+/) do
          [behind, ahead] -> {parse_int(ahead), parse_int(behind)}
          _ -> {nil, nil}
        end

      :error ->
        {nil, nil}
    end
  end

  defp changes(git, workspace) do
    with {:ok, prefix} <- run(git, workspace, ["rev-parse", "--show-prefix"]),
         {:ok, out} <-
           run(git, workspace, [
             "status",
             "--porcelain=v1",
             "--untracked-files=all",
             "--",
             "."
           ]) do
      prefix = String.trim(prefix)

      for <<code::binary-size(2), " ", path::binary>> <- String.split(out, "\n", trim: true) do
        %{code: String.trim(code), path: String.replace_prefix(path, prefix, "")}
      end
    else
      _ -> []
    end
  end

  defp commits(git, workspace) do
    case run(git, workspace, ["log", "-n", "8", "--format=%h\t%s\t%an\t%ar"]) do
      {:ok, out} ->
        for line <- String.split(out, "\n", trim: true),
            [hash, subject, author, at] <- [String.split(line, "\t", parts: 4)],
            do: %{hash: hash, subject: subject, author: author, at: at}

      :error ->
        []
    end
  end

  # stderr is merged and discarded: several of these questions have a
  # perfectly ordinary "no" answer (no upstream, no commits yet) that git
  # reports on stderr, and it is not the operator's problem.
  defp run(git, workspace, args),
    do: Executable.run(git, ["-C", workspace | args], stderr: :merge)

  defp one_line({:ok, out}), do: String.trim(out)
  defp one_line(:error), do: nil

  defp parse_int(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> nil
    end
  end

  ## Worktrees
  #
  # A worktree is how two agents work on one repository without fighting over
  # the same files. Khymeia creates them and can remove them; it never merges
  # anything, because deciding what reaches a branch is the developer's job.

  @worktree_timeout 60_000

  @doc "The repository a path belongs to, or `:unavailable` outside one."
  @spec repository(String.t()) :: String.t() | :unavailable
  def repository(path) do
    case git_cmd(path, ["rev-parse", "--show-toplevel"]) do
      {:ok, root} -> String.trim(root)
      _ -> :unavailable
    end
  end

  @doc "The commit `HEAD` points at, or `nil`."
  def head(path) do
    case git_cmd(path, ["rev-parse", "HEAD"]) do
      {:ok, sha} -> String.trim(sha)
      _ -> nil
    end
  end

  @doc """
  Adds a worktree at `path` on a new `branch`, starting from `base`.

  Fails rather than improvising if the branch or the directory already
  exists: silently reusing either would put an agent somewhere the caller
  did not mean.
  """
  @spec add_worktree(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, %{path: String.t(), branch: String.t(), base_commit: String.t()}}
          | {:error, String.t()}
  def add_worktree(repository, path, branch, base) do
    with {:ok, _} <-
           git_cmd(repository, ["worktree", "add", "-b", branch, path, base],
             timeout: @worktree_timeout
           ) do
      {:ok, %{path: path, branch: branch, base_commit: head(path)}}
    end
  end

  @doc """
  Removes a worktree directory. The branch survives: removing a worktree is
  about the checkout, not about the work.
  """
  @spec remove_worktree(String.t(), String.t(), keyword()) :: :ok | {:error, String.t()}
  def remove_worktree(repository, path, opts \\ []) do
    args = ["worktree", "remove"] ++ if(opts[:force], do: ["--force"], else: []) ++ [path]

    case git_cmd(repository, args, timeout: @worktree_timeout) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc "Deletes a branch. `force: true` deletes it even if it was never merged."
  @spec delete_branch(String.t(), String.t(), keyword()) :: :ok | {:error, String.t()}
  def delete_branch(repository, branch, opts \\ []) do
    flag = if opts[:force], do: "-D", else: "-d"

    case git_cmd(repository, ["branch", flag, branch]) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc "Worktrees git knows about, as `%{path:, branch:, head:}`."
  @spec worktrees(String.t()) :: [map()]
  def worktrees(repository) do
    case git_cmd(repository, ["worktree", "list", "--porcelain"]) do
      {:ok, out} -> parse_worktrees(out)
      _ -> []
    end
  end

  defp parse_worktrees(out) do
    out
    |> String.split("\n\n", trim: true)
    |> Enum.map(fn block ->
      Enum.reduce(String.split(block, "\n", trim: true), %{}, fn
        "worktree " <> path, acc -> Map.put(acc, :path, path)
        "HEAD " <> sha, acc -> Map.put(acc, :head, sha)
        "branch refs/heads/" <> branch, acc -> Map.put(acc, :branch, branch)
        _, acc -> acc
      end)
    end)
    |> Enum.filter(&Map.has_key?(&1, :path))
  end

  @typedoc "What an agent did in a worktree, compared with where it started."
  @type work :: %{
          files: non_neg_integer(),
          insertions: non_neg_integer(),
          deletions: non_neg_integer(),
          untracked: non_neg_integer(),
          commits: non_neg_integer()
        }

  @doc """
  How far a worktree has moved from `base`: tracked changes (committed or
  not), untracked files, and commits made. `:unavailable` when git cannot say.
  """
  @spec work_done(String.t(), String.t()) :: work() | :unavailable
  def work_done(path, base) do
    case git_cmd(path, ["diff", "--numstat", base]) do
      {:ok, out} ->
        {files, insertions, deletions} = sum_numstat(out)

        %{
          files: files,
          insertions: insertions,
          deletions: deletions,
          untracked: count_untracked(path),
          commits: count_commits(path, base)
        }

      _ ->
        :unavailable
    end
  end

  defp sum_numstat(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.reduce({0, 0, 0}, fn line, {files, added, removed} ->
      case String.split(line, "\t", parts: 3) do
        # A binary file reports "-" instead of a count.
        [a, d, _path] -> {files + 1, added + to_int(a), removed + to_int(d)}
        _ -> {files, added, removed}
      end
    end)
  end

  defp to_int(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp count_untracked(path) do
    case git_cmd(path, ["ls-files", "--others", "--exclude-standard"]) do
      {:ok, out} -> out |> String.split("\n", trim: true) |> length()
      _ -> 0
    end
  end

  defp count_commits(path, base) do
    case git_cmd(path, ["rev-list", "--count", base <> "..HEAD"]) do
      {:ok, out} -> out |> String.trim() |> to_int()
      _ -> 0
    end
  end

  # Unlike the read-only helpers above, these report *why* they failed: the
  # user is asking for an action and deserves git's own explanation.
  defp git_cmd(path, args, opts \\ []) do
    case git() do
      {:ok, git} ->
        task =
          Task.async(fn ->
            System.cmd(git, ["-C", path | args], stderr_to_stdout: true)
          end)

        case Task.yield(task, Keyword.get(opts, :timeout, 10_000)) ||
               Task.shutdown(task, :brutal_kill) do
          {:ok, {out, 0}} -> {:ok, out}
          {:ok, {out, _}} -> {:error, String.trim(out)}
          _ -> {:error, "git did not answer in time"}
        end

      :unavailable ->
        {:error, "git is not installed"}
    end
  end

  @doc "Paths whose state differs between two snapshots."
  def changed(:unavailable, _), do: nil
  def changed(_, :unavailable), do: nil

  def changed(before, now) do
    (Map.keys(before) ++ Map.keys(now))
    |> Enum.uniq()
    |> Enum.filter(&(Map.get(before, &1) != Map.get(now, &1)))
    |> Enum.sort()
  end

  @doc "Diff of tracked `paths` against HEAD, truncated to `max_bytes`."
  @spec diff(String.t(), [String.t()], pos_integer()) :: {:ok, String.t()} | :unavailable
  def diff(_workspace, [], _max), do: {:ok, ""}

  def diff(workspace, paths, max_bytes) do
    with {:ok, git} <- git(),
         {:ok, out} <- diff_against_head(git, workspace, paths) do
      if byte_size(out) > max_bytes,
        do: {:ok, binary_part(out, 0, max_bytes) <> "\n[diff truncated by Khymeia]\n"},
        else: {:ok, out}
    else
      _ -> :unavailable
    end
  end

  defp diff_against_head(git, workspace, paths) do
    # A repository without commits has no HEAD; fall back to the index.
    with :error <-
           Executable.run(git, ["-C", workspace, "diff", "HEAD", "--" | paths], timeout: 15_000) do
      Executable.run(git, ["-C", workspace, "diff", "--" | paths], timeout: 15_000)
    end
  end

  defp hash(git, workspace, paths) do
    case Executable.run(git, ["-C", workspace, "hash-object", "--" | paths], timeout: 15_000) do
      {:ok, out} -> String.split(out, "\n", trim: true)
      :error -> Enum.map(paths, fn _ -> :unknown end)
    end
  end

  # `XY path\0` entries; renames carry an extra `orig\0` entry.
  defp parse_porcelain(out) do
    out
    |> String.split(<<0>>, trim: true)
    |> collect([])
  end

  defp collect([], acc), do: Enum.reverse(acc)

  defp collect([<<x, _y, " ", path::binary>> | rest], acc) when x in [?R, ?C] do
    collect(Enum.drop(rest, 1), [path | acc])
  end

  defp collect([<<_x, _y, " ", path::binary>> | rest], acc), do: collect(rest, [path | acc])
  defp collect([_ | rest], acc), do: collect(rest, acc)

  defp git do
    case Executable.find_in_path("git") do
      {:ok, git} -> {:ok, git}
      :not_found -> :unavailable
    end
  end
end
