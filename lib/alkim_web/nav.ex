defmodule AlkimWeb.Nav do
  @moduledoc """
  Keeps the shell's sidebar in sync for every LiveView.

  Mounted as a hook, it owns the project list, the per-project count of
  active work and the harness list, and refreshes them from the `"nav"`
  topic. Pages never subscribe to the global session or workflow topics for
  this: a detail view must only receive its own session's events.
  """

  import Phoenix.Component
  import Phoenix.LiveView

  alias Alkim.{Projects, Runtime}
  alias Alkim.Runtime.EventBus

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) do
      EventBus.subscribe_nav()
      EventBus.subscribe_harnesses()
    end

    socket =
      socket
      |> assign(nav: %{harnesses: Runtime.harnesses(), projects: [], active_counts: %{}})
      |> refresh()
      |> attach_hook(:nav, :handle_info, &handle/2)

    {:cont, socket}
  end

  defp handle(:nav_changed, socket), do: {:halt, refresh(socket)}

  defp handle({:harnesses, harnesses}, socket),
    do: {:halt, put(socket, :harnesses, harnesses)}

  defp handle(_message, socket), do: {:cont, socket}

  @doc "Reloads the project list and the per-project count of active work."
  def refresh(socket) do
    assign(socket,
      nav: %{
        socket.assigns.nav
        | projects: Projects.list(),
          active_counts: Projects.active_counts()
      }
    )
  end

  defp put(socket, key, value),
    do: assign(socket, nav: Map.put(socket.assigns.nav, key, value))
end
