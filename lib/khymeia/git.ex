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

  defp run(git, workspace, args), do: Executable.run(git, ["-C", workspace | args])

  defp one_line({:ok, out}), do: String.trim(out)
  defp one_line(:error), do: nil

  defp parse_int(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> nil
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
