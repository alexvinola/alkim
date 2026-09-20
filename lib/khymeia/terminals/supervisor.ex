defmodule Khymeia.Terminals.Supervisor do
  @moduledoc """
  DynamicSupervisor of interactive terminals.

  Children are `:temporary`: a terminal that dies is gone, because its
  pseudo-terminal and the harness on it are gone too. Restarting the process
  would produce an empty terminal pretending to be the old one.
  """

  use DynamicSupervisor

  def start_link(opts), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  def start_terminal(opts),
    do: DynamicSupervisor.start_child(__MODULE__, {Khymeia.Terminals.Server, opts})
end
