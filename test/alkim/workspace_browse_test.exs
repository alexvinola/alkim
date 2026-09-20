defmodule Alkim.WorkspaceBrowseTest do
  use ExUnit.Case, async: false

  alias Alkim.Workspace

  setup do
    [root] = Workspace.roots()
    dir = Path.join(root, "browse-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "Zeta"))
    File.mkdir_p!(Path.join(dir, "alpha/.git"))
    File.mkdir_p!(Path.join(dir, ".secret"))
    File.write!(Path.join(dir, "file.txt"), "")
    {:ok, root: root, dir: dir}
  end

  test "lists subfolders only, sorted, with git markers", %{dir: dir} do
    assert {:ok, listing} = Workspace.browse(dir)
    assert listing.path == dir
    assert Enum.map(listing.dirs, & &1.name) == ["alpha", "Zeta"]
    assert [%{git: true}, %{git: false}] = listing.dirs
    assert listing.parent == Path.dirname(dir)
  end

  test "hidden folders only on request", %{dir: dir} do
    assert {:ok, %{dirs: dirs}} = Workspace.browse(dir, hidden: true)
    assert ".secret" in Enum.map(dirs, & &1.name)
  end

  test "a root has no parent, and nothing outside the roots can be listed", %{
    root: root,
    dir: dir
  } do
    assert {:ok, %{parent: nil}} = Workspace.browse(root)
    assert {:error, :outside_roots} = Workspace.browse("/etc")
    assert {:error, :outside_roots} = Workspace.browse(dir <> String.duplicate("/..", 30))
    File.ln_s!("/etc", Path.join(dir, "escape"))
    assert {:error, :outside_roots} = Workspace.browse(Path.join(dir, "escape"))
  end
end
