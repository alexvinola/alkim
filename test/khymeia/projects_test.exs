defmodule Khymeia.ProjectsTest do
  use Khymeia.RuntimeCase, async: false

  alias Khymeia.Projects

  test "a project's path is validated and its name defaults to the folder", %{
    workspace: workspace
  } do
    {:ok, project} = Projects.create(%{"path" => workspace})

    assert project.path == workspace
    assert project.name == Path.basename(workspace)
  end

  test "a path outside the allowed roots is rejected" do
    assert {:error, changeset} = Projects.create(%{"path" => "/etc"})
    assert %{path: [_ | _]} = Ecto.Changeset.traverse_errors(changeset, & &1)
  end

  test "the innermost project wins for a nested workspace", %{workspace: workspace} do
    nested = Path.join(workspace, "apps/web")
    File.mkdir_p!(nested)

    {:ok, outer} = Projects.create(%{"path" => workspace})
    assert Projects.for_workspace(nested).id == outer.id

    {:ok, inner} = Projects.create(%{"path" => nested})
    assert Projects.for_workspace(nested).id == inner.id
    assert Projects.for_workspace(workspace).id == outer.id
  end

  test "starting a session registers its workspace as a project", %{workspace: workspace} do
    session = start_fake!(workspace, "success")
    await_event(session.id, :waiting)

    project = Projects.get_by_path(workspace)
    assert project
    assert session.project_id == project.id
  end

  test "removing a project keeps its sessions in history", %{workspace: workspace} do
    session = start_fake!(workspace, "success")
    await_event(session.id, :waiting)

    project = Projects.get_by_path(workspace)
    {:ok, _} = Projects.delete(project)

    assert Projects.get(project.id) == nil
    assert %{project_id: nil} = Khymeia.Sessions.get(session.id)
  end
end
