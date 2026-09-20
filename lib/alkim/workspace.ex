defmodule Alkim.Workspace do
  @moduledoc """
  Validates the directory a harness will run in.

  A workspace must be an existing directory inside one of the allowed roots
  (`ALKIM_WORKSPACE_ROOTS`, colon-separated; defaults to the user's home
  directory). The check runs on the *canonical* path — `~` expanded, `.`/`..`
  collapsed and symlinks resolved — so neither `../../etc` nor a symlink
  pointing outside the roots can escape.
  """

  @max_symlinks 32

  @type error ::
          :empty
          | :not_absolute
          | :not_found
          | :not_a_directory
          | :outside_roots
          | :too_many_links

  @spec validate(String.t() | nil) :: {:ok, String.t()} | {:error, error()}
  def validate(nil), do: {:error, :empty}

  def validate(path) when is_binary(path) do
    path = String.trim(path)

    cond do
      path == "" ->
        {:error, :empty}

      String.contains?(path, <<0>>) ->
        {:error, :not_found}

      not (String.starts_with?(path, "/") or String.starts_with?(path, "~")) ->
        {:error, :not_absolute}

      true ->
        path |> Path.expand() |> check()
    end
  end

  @max_entries 1_000

  @type listing :: %{
          path: String.t(),
          parent: String.t() | nil,
          dirs: [%{name: String.t(), path: String.t(), git: boolean()}],
          git: boolean(),
          truncated: boolean()
        }

  @doc """
  Lists the subdirectories of `path` for the workspace picker.

  `path` goes through `validate/1` first, so browsing is confined to the
  allowed roots exactly like starting a session is: `..` and symlinks cannot
  escape them. `parent` is `nil` at a root. Hidden directories are skipped
  unless `hidden: true`. Only names are read — no file contents.
  """
  @spec browse(String.t(), keyword()) :: {:ok, listing()} | {:error, error() | :unreadable}
  def browse(path, opts \\ []) do
    hidden? = Keyword.get(opts, :hidden, false)

    with {:ok, dir} <- validate(path),
         {:ok, names} <- ls(dir) do
      dirs =
        names
        |> Enum.reject(&(not hidden? and String.starts_with?(&1, ".")))
        |> Enum.sort_by(&String.downcase/1)
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.filter(&File.dir?/1)

      {shown, rest} = Enum.split(dirs, @max_entries)

      {:ok,
       %{
         path: dir,
         parent: if(dir in roots(), do: nil, else: Path.dirname(dir)),
         dirs: Enum.map(shown, &%{name: Path.basename(&1), path: &1, git: git?(&1)}),
         git: git?(dir),
         truncated: rest != []
       }}
    end
  end

  defp ls(dir) do
    case File.ls(dir) do
      {:ok, names} -> {:ok, names}
      {:error, _} -> {:error, :unreadable}
    end
  end

  defp git?(dir), do: File.exists?(Path.join(dir, ".git"))

  @doc "Allowed roots, canonicalized."
  def roots do
    Application.get_env(:alkim, :workspace_roots, [System.user_home!()])
    |> Enum.flat_map(fn root ->
      case canonical(Path.expand(root)) do
        {:ok, canonical} -> [canonical]
        {:error, _} -> []
      end
    end)
  end

  def error_message(:empty), do: "choose a workspace directory"
  def error_message(:not_absolute), do: "use an absolute path (or one starting with ~)"
  def error_message(:not_found), do: "directory does not exist"
  def error_message(:not_a_directory), do: "path is not a directory"
  def error_message(:too_many_links), do: "too many symbolic links"
  def error_message(:unreadable), do: "this directory cannot be read (permission denied?)"

  def error_message(:outside_roots),
    do: "outside the allowed workspace roots (#{Enum.join(roots(), ", ")})"

  defp check(path) do
    with {:ok, canonical} <- canonical(path),
         :ok <- directory(canonical),
         :ok <- inside_roots(canonical) do
      {:ok, canonical}
    end
  end

  defp directory(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, _} -> {:error, :not_a_directory}
      {:error, _} -> {:error, :not_found}
    end
  end

  defp inside_roots(path) do
    if Enum.any?(roots(), &(path == &1 or String.starts_with?(path, &1 <> "/"))) and
         path != "/",
       do: :ok,
       else: {:error, :outside_roots}
  end

  # Resolves every symlink component of an absolute, expanded path.
  @doc false
  def canonical(path), do: resolve(Path.split(path), "/", 0)

  defp resolve(_parts, _acc, depth) when depth > @max_symlinks, do: {:error, :too_many_links}
  defp resolve([], acc, _depth), do: {:ok, acc}
  defp resolve(["/" | rest], _acc, depth), do: resolve(rest, "/", depth)

  defp resolve([part | rest], acc, depth) do
    candidate = Path.join(acc, part)

    case File.read_link(candidate) do
      {:ok, target} ->
        target = Path.expand(target, acc)
        resolve(Path.split(target) ++ rest, "/", depth + 1)

      {:error, :einval} ->
        resolve(rest, candidate, depth)

      {:error, _} ->
        if File.exists?(candidate),
          do: resolve(rest, candidate, depth),
          else: {:error, :not_found}
    end
  end
end
