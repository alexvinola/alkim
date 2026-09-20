defmodule Alkim.WorkspaceTest do
  use ExUnit.Case, async: false

  alias Alkim.Workspace

  setup do
    [root] = Application.fetch_env!(:alkim, :workspace_roots)
    File.mkdir_p!(root)
    {:ok, root} = Workspace.canonical(root)
    dir = Path.join(root, "ws-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "project"))
    {:ok, dir: dir}
  end

  test "accepts a directory inside the allowed roots", %{dir: dir} do
    assert {:ok, path} = Workspace.validate(Path.join(dir, "project"))
    assert path == Path.join(dir, "project")
  end

  test "normalizes . and .. segments", %{dir: dir} do
    assert {:ok, path} = Workspace.validate(dir <> "/project/../project/.")
    assert path == Path.join(dir, "project")
  end

  test "rejects path traversal out of the roots", %{dir: dir} do
    assert {:error, :outside_roots} =
             Workspace.validate(dir <> String.duplicate("/..", 20) <> "/etc")
  end

  test "rejects symlinks that point outside the roots", %{dir: dir} do
    link = Path.join(dir, "escape")
    File.ln_s!("/etc", link)
    assert {:error, :outside_roots} = Workspace.validate(link)
  end

  test "follows symlinks that stay inside the roots", %{dir: dir} do
    link = Path.join(dir, "alias")
    File.ln_s!(Path.join(dir, "project"), link)
    assert {:ok, path} = Workspace.validate(link)
    assert path == Path.join(dir, "project")
  end

  test "rejects relative, missing, empty and non-directory paths", %{dir: dir} do
    file = Path.join(dir, "file.txt")
    File.write!(file, "")

    assert {:error, :not_absolute} = Workspace.validate("relative/path")
    assert {:error, :not_found} = Workspace.validate(Path.join(dir, "nope"))
    assert {:error, :empty} = Workspace.validate("  ")
    assert {:error, :empty} = Workspace.validate(nil)
    assert {:error, :not_a_directory} = Workspace.validate(file)
    assert {:error, :not_found} = Workspace.validate(dir <> <<0>>)
  end

  test "the filesystem root is never a workspace" do
    assert {:error, :outside_roots} = Workspace.validate("/")
  end
end
