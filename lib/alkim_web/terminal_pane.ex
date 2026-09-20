defmodule AlkimWeb.TerminalPane do
  @moduledoc """
  The plumbing behind an embedded terminal, shared by every page that shows
  one.

  A terminal pane is the same three exchanges wherever it appears: the
  client says it attached and asks for what it missed, the client sends
  keystrokes and its window size, and the server pushes bytes back. Pages
  differ in *which* terminal they show and what else they do about it — a
  project lists its own, a workflow run groups them by role — so this owns
  the exchanges and leaves the choosing to the page.

  It is an `on_mount` hook rather than a component because the work is
  events, not markup: `attach_hook/4` puts it in front of the LiveView's own
  `handle_event/3` and `handle_info/2`, halting what belongs to the terminal
  and letting everything else through untouched.

      on_mount AlkimWeb.TerminalPane

  The page keeps one assign, `@terminal`, and calls `attach/2` when the
  shown terminal changes. Only one terminal is subscribed at a time: a view
  paints the terminal it shows and no other.
  """

  import Phoenix.Component, only: [assign: 3, assign_new: 3]
  import Phoenix.LiveView

  alias Alkim.Terminals

  def on_mount(:default, _params, _session, socket) do
    {:cont,
     socket
     |> assign_new(:terminal, fn -> nil end)
     |> assign_new(:terminal_attached, fn -> nil end)
     |> attach_hook(:terminal_pane_events, :handle_event, &event/3)
     |> attach_hook(:terminal_pane_info, :handle_info, &info/2)}
  end

  # The browser attached: replay what it missed before it started listening.
  defp event("terminal_attached", _params, %{assigns: %{terminal: nil}} = socket),
    do: {:halt, socket}

  defp event("terminal_attached", _params, socket) do
    case Terminals.attach(socket.assigns.terminal.id) do
      {:ok, terminal, scrollback} ->
        # The snapshot is a call to the terminal's own process, so every byte
        # broadcast before it is in this scrollback and every byte after it
        # is still behind us in the mailbox: replaying here paints each one
        # exactly once. Output is dropped until this point precisely so that
        # holds — see `info/2`.
        socket = assign(socket, :terminal, terminal)
        socket = assign(socket, :terminal_attached, terminal.id)
        {:halt, write(socket, terminal.id, scrollback, reset: true)}

      :error ->
        {:halt, socket}
    end
  end

  defp event("terminal_keys", %{"data" => data}, socket) do
    if socket.assigns.terminal, do: Terminals.send_keys(socket.assigns.terminal.id, data)
    {:halt, socket}
  end

  defp event("terminal_resize", %{"rows" => rows, "cols" => cols}, socket) do
    if socket.assigns.terminal, do: Terminals.resize(socket.assigns.terminal.id, rows, cols)
    {:halt, socket}
  end

  defp event(_name, _params, socket), do: {:cont, socket}

  # Nothing is sent to a pane that has not attached yet. A terminal is
  # subscribed the moment it is shown, but the client's xterm only exists
  # once the browser has applied the patch — bytes sent in between would be
  # painted and then painted again by the replay.
  defp info({:terminal_output, id, data}, socket) do
    if socket.assigns[:terminal_attached] == id,
      do: {:halt, write(socket, id, data)},
      else: {:halt, socket}
  end

  # Lifecycle passes through: the pane keeps the record it is showing fresh,
  # and the page still gets to reload whatever lists it keeps beside it.
  defp info({:terminal_status, terminal}, socket) do
    if socket.assigns[:terminal] && socket.assigns.terminal.id == terminal.id,
      do: {:cont, assign(socket, :terminal, terminal)},
      else: {:cont, socket}
  end

  defp info(_message, socket), do: {:cont, socket}

  @doc """
  Shows `terminal` in this pane, moving the subscription with it.
  """
  def attach(socket, terminal) do
    current = socket.assigns[:terminal]
    if current && current.id != terminal.id, do: Terminals.unsubscribe(current.id)

    if connected?(socket) and (is_nil(current) or current.id != terminal.id) do
      Terminals.subscribe(terminal.id)
    end

    socket
    |> assign(:terminal, terminal)
    |> assign(:terminal_attached, if(current && current.id == terminal.id, do: terminal.id))
  end

  @doc "Shows nothing, releasing whatever was subscribed."
  def detach(socket) do
    if socket.assigns[:terminal], do: Terminals.unsubscribe(socket.assigns.terminal.id)
    socket |> assign(:terminal, nil) |> assign(:terminal_attached, nil)
  end

  @doc """
  Pushes bytes to the client. Base64 because terminal output is not
  guaranteed to be valid UTF-8, and one bad byte must not break the channel.
  """
  def write(socket, id, data, opts \\ [])

  def write(socket, id, data, opts) when byte_size(data) > 0 do
    push_event(socket, "terminal:write", %{
      id: id,
      data: Base.encode64(data),
      reset: Keyword.get(opts, :reset, false)
    })
  end

  def write(socket, id, _data, opts) do
    if Keyword.get(opts, :reset, false),
      do: push_event(socket, "terminal:write", %{id: id, data: "", reset: true}),
      else: socket
  end
end
