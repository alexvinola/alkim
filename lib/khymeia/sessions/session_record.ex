defmodule Khymeia.Sessions.SessionRecord do
  @moduledoc """
  Persistent history of a session: enough operational context to know what
  ran, where, and how it ended. Never stores output, credentials or tokens.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "sessions" do
    field :harness, :string
    field :workspace, :string
    field :prompt, :string
    field :model, :string
    field :permission_mode, :string
    field :status, Ecto.Enum, values: Khymeia.Session.statuses()
    field :harness_ref, :string
    field :turns, :integer, default: 0
    field :exit_code, :integer
    field :error, :string
    field :metadata, :map, default: %{}
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    timestamps()
  end

  @create ~w(id harness workspace prompt model permission_mode status started_at metadata)a
  @update ~w(status harness_ref turns exit_code error metadata started_at completed_at)a

  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, @create)
    |> validate_required([:id, :harness, :workspace, :prompt, :status])
  end

  def update_changeset(record, attrs), do: cast(record, attrs, @update)
end
