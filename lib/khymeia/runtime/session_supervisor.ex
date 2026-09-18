defmodule Khymeia.Runtime.SessionSupervisor do
  @moduledoc """
  `DynamicSupervisor` holding one `Khymeia.Runtime.SessionServer` per session.

  Children are `:temporary`, so a crashing session is neither restarted nor
  counted towards restart intensity: one misbehaving harness cannot bring
  down its siblings or this supervisor.
  """

  use DynamicSupervisor

  alias Khymeia.Runtime.SessionServer

  def start_link(opts), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  def start_session(opts), do: DynamicSupervisor.start_child(__MODULE__, {SessionServer, opts})

  def children, do: DynamicSupervisor.which_children(__MODULE__)

  @impl true
  def init(_opts) do
    max = Application.get_env(:khymeia, :max_sessions, :infinity)
    DynamicSupervisor.init(strategy: :one_for_one, max_children: max)
  end
end
