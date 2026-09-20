defmodule Khymeia.Projects.Project do
  @moduledoc """
  A directory the user works in, given a name.

  A project is just a validated workspace plus a label: sessions and
  workflows belong to one, which is what lets the UI group work by place
  instead of by path string. It holds no credentials and no agent state.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Khymeia.Workspace

  @primary_key {:id, :binary_id, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "projects" do
    field :name, :string
    field :path, :string
    field :last_opened_at, :utc_datetime_usec

    timestamps()
  end

  @doc """
  Casts and validates a project. The path goes through `Khymeia.Workspace`,
  so a project can never point outside the allowed roots.
  """
  def changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :path, :last_opened_at])
    |> update_change(:name, &String.trim/1)
    |> canonicalize_path()
    |> default_name()
    |> validate_required([:name, :path])
    |> validate_length(:name, max: 80)
    |> unique_constraint(:path)
  end

  defp canonicalize_path(changeset) do
    case fetch_change(changeset, :path) do
      {:ok, path} ->
        case Workspace.validate(path) do
          {:ok, canonical} -> put_change(changeset, :path, canonical)
          {:error, reason} -> add_error(changeset, :path, Workspace.error_message(reason))
        end

      :error ->
        changeset
    end
  end

  defp default_name(changeset) do
    case {get_field(changeset, :name), get_field(changeset, :path)} do
      {name, path} when name in [nil, ""] and is_binary(path) ->
        put_change(changeset, :name, Path.basename(path))

      _ ->
        changeset
    end
  end
end
