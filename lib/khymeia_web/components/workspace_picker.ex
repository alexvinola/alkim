defmodule KhymeiaWeb.WorkspacePicker do
  @moduledoc """
  Modal directory browser for choosing a workspace.

  A browser's native folder dialog cannot be used: for privacy it never
  reveals the absolute path of the chosen folder, and the path is what the
  runtime needs. So the listing comes from the runtime itself
  (`Khymeia.Workspace.browse/2`), confined to the allowed workspace roots.

  Usage — the trigger sits inside the form (it renders the hidden input the
  form submits); the component renders the modal and tells the parent
  LiveView `{:workspace_selected, path}`:

      <.workspace_field name="session[workspace]" value={@params["workspace"]} error={...} />
      <.live_component module={KhymeiaWeb.WorkspacePicker} id="workspace-picker" value={@params["workspace"]} />
  """

  use KhymeiaWeb, :live_component

  alias Khymeia.{Runtime, Workspace}
  alias Phoenix.LiveView.JS

  @doc "Trigger button + hidden input, placed inside the form."
  attr :name, :string, required: true
  attr :value, :string, default: nil
  attr :error, :string, default: nil
  attr :picker, :string, default: "workspace-picker"

  def workspace_field(assigns) do
    ~H"""
    <div class="k-field">
      <span class="k-label">Workspace</span>
      <input type="hidden" name={@name} value={@value} id={"#{@picker}-value"} />
      <button
        type="button"
        class={["k-picker-trigger", @error && "k-picker-trigger-error"]}
        phx-click={JS.push("open", target: "##{@picker}")}
        id={"#{@picker}-trigger"}
      >
        <.icon name="hero-folder" class="size-4 k-muted" />
        <span class="k-mono k-truncate">{display(@value) || "Choose a folder…"}</span>
        <span class="k-hint" style="margin-left:auto">Browse…</span>
      </button>
      <span :if={@error} class="k-error">{@error}</span>
    </div>
    """
  end

  @impl true
  def mount(socket) do
    {:ok, assign(socket, open: false, listing: nil, error: nil, hidden: false, filter: "")}
  end

  @impl true
  def update(%{open: true} = assigns, socket),
    do: {:ok, socket |> assign(id: assigns.id) |> open()}

  def update(assigns, socket), do: {:ok, assign(socket, value: assigns[:value], id: assigns.id)}

  @impl true
  def handle_event("open", _params, socket), do: {:noreply, open(socket)}

  def handle_event("close", _params, socket), do: {:noreply, assign(socket, open: false)}

  def handle_event("cd", %{"path" => path}, socket),
    do: {:noreply, socket |> assign(filter: "") |> browse(path)}

  def handle_event("filter", %{"filter" => filter}, socket),
    do: {:noreply, assign(socket, filter: filter)}

  def handle_event("toggle_hidden", _params, socket) do
    socket = assign(socket, hidden: not socket.assigns.hidden)
    {:noreply, browse(socket, socket.assigns.listing && socket.assigns.listing.path)}
  end

  def handle_event("select", %{"path" => path}, socket) do
    case Workspace.validate(path) do
      {:ok, path} ->
        send(self(), {:workspace_selected, path})
        {:noreply, assign(socket, open: false, value: path)}

      {:error, reason} ->
        {:noreply, assign(socket, error: Workspace.error_message(reason))}
    end
  end

  defp open(socket) do
    start =
      if match?({:ok, _}, Workspace.validate(socket.assigns.value || "")),
        do: socket.assigns.value

    socket =
      assign(socket,
        open: true,
        filter: "",
        recent: Runtime.recent_workspaces(),
        roots: Workspace.roots()
      )

    browse(socket, start || List.first(socket.assigns.roots))
  end

  defp browse(socket, nil),
    do: assign(socket, listing: nil, error: "no workspace root is configured")

  defp browse(socket, path) do
    case Workspace.browse(path, hidden: socket.assigns.hidden) do
      {:ok, listing} -> assign(socket, listing: listing, error: nil)
      {:error, reason} -> assign(socket, error: Workspace.error_message(reason))
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <div
        :if={@open}
        class="k-modal-backdrop"
        phx-window-keydown="close"
        phx-key="Escape"
        phx-target={@myself}
      >
        <div
          class="k-modal"
          role="dialog"
          aria-modal="true"
          aria-labelledby={"#{@id}-title"}
          phx-click-away="close"
          phx-target={@myself}
        >
          <header class="k-modal-head">
            <h2 class="k-h1" id={"#{@id}-title"} style="font-size:16px">Choose a workspace</h2>
            <button
              type="button"
              class="k-btn k-btn-ghost"
              phx-click="close"
              phx-target={@myself}
              aria-label="Close"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </header>

          <div class="k-modal-body">
            <aside class="k-picker-side">
              <div :if={@recent != []}>
                <span class="k-h2">Recent</span>
                <button
                  :for={path <- @recent}
                  type="button"
                  class="k-picker-link"
                  phx-click="cd"
                  phx-value-path={path}
                  phx-target={@myself}
                  title={path}
                >
                  <.icon name="hero-clock" class="size-3.5" />
                  <span class="k-truncate">{Path.basename(path)}</span>
                </button>
              </div>
              <div>
                <span class="k-h2">Roots</span>
                <button
                  :for={root <- @roots}
                  type="button"
                  class="k-picker-link"
                  phx-click="cd"
                  phx-value-path={root}
                  phx-target={@myself}
                  title={root}
                >
                  <.icon name="hero-home" class="size-3.5" />
                  <span class="k-truncate">{display(root)}</span>
                </button>
              </div>
            </aside>

            <section class="k-picker-main">
              <nav :if={@listing} class="k-crumbs" aria-label="Path">
                <button
                  :for={{label, path} <- crumbs(@listing.path, @roots)}
                  type="button"
                  phx-click="cd"
                  phx-value-path={path}
                  phx-target={@myself}
                >
                  {label}
                </button>
              </nav>

              <form
                id={"#{@id}-filter-form"}
                class="k-picker-tools"
                phx-change="filter"
                phx-submit="filter"
                phx-target={@myself}
              >
                <input
                  name="filter"
                  value={@filter}
                  class="k-input"
                  placeholder="Filter folders"
                  autocomplete="off"
                  phx-debounce="100"
                  phx-mounted={JS.focus()}
                  id={"#{@id}-filter"}
                />
                <label class="k-hint k-check-label">
                  <input
                    type="checkbox"
                    checked={@hidden}
                    phx-click="toggle_hidden"
                    phx-target={@myself}
                  /> hidden
                </label>
              </form>

              <div :if={@error} class="k-banner k-banner-error">{@error}</div>

              <ul :if={@listing} class="k-picker-list" id={"#{@id}-list"}>
                <li :if={@listing.parent}>
                  <button
                    type="button"
                    phx-click="cd"
                    phx-value-path={@listing.parent}
                    phx-target={@myself}
                  >
                    <.icon name="hero-arrow-uturn-left" class="size-4 k-muted" />
                    <span class="k-muted">..</span>
                  </button>
                </li>
                <li :for={dir <- visible(@listing.dirs, @filter)}>
                  <button
                    type="button"
                    phx-click="cd"
                    phx-value-path={dir.path}
                    phx-target={@myself}
                    title={dir.path}
                  >
                    <.icon name="hero-folder" class="size-4 k-muted" />
                    <span class="k-truncate">{dir.name}</span>
                    <span :if={dir.git} class="k-tag">git</span>
                  </button>
                </li>
                <li :if={visible(@listing.dirs, @filter) == []} class="k-empty">
                  {if @filter == "", do: "No subfolders.", else: "No folder matches “#{@filter}”."}
                </li>
                <li :if={@listing.truncated} class="k-hint" style="padding:.5rem .75rem">
                  Showing the first 1000 folders — use the filter.
                </li>
              </ul>
            </section>
          </div>

          <footer :if={@listing} class="k-modal-foot">
            <span class="k-mono k-truncate" title={@listing.path}>
              {display(@listing.path)}
              <span :if={@listing.git} class="k-tag">git</span>
            </span>
            <div style="display:flex;gap:.5rem;flex:none">
              <button type="button" class="k-btn" phx-click="close" phx-target={@myself}>Cancel</button>
              <button
                type="button"
                class="k-btn k-btn-primary"
                phx-click="select"
                phx-value-path={@listing.path}
                phx-target={@myself}
                id={"#{@id}-select"}
              >
                Select this folder
              </button>
            </div>
          </footer>
        </div>
      </div>
    </div>
    """
  end

  defp visible(dirs, ""), do: dirs

  defp visible(dirs, filter) do
    needle = String.downcase(String.trim(filter))
    Enum.filter(dirs, &String.contains?(String.downcase(&1.name), needle))
  end

  # Breadcrumbs from the root that contains `path` down to `path`.
  defp crumbs(path, roots) do
    root =
      roots
      |> Enum.filter(&(path == &1 or String.starts_with?(path, &1 <> "/")))
      |> Enum.max_by(&byte_size/1, fn -> "/" end)

    rest = path |> String.replace_prefix(root, "") |> Path.split() |> Enum.reject(&(&1 == "/"))

    rest
    |> Enum.scan({display(root), root}, fn part, {_, parent} ->
      {part, Path.join(parent, part)}
    end)
    |> then(&[{display(root), root} | &1])
  end

  defp display(nil), do: nil
  defp display(""), do: nil

  defp display(path) do
    home = System.user_home() || ""

    if home != "" and String.starts_with?(path, home),
      do: "~" <> String.trim_leading(path, home),
      else: path
  end
end
