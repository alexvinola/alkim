defmodule AlkimWeb.Layouts do
  @moduledoc """
  The application shell: a slim top bar, a sidebar listing the projects (and
  the sessions of the one being viewed) and the page itself.

  The sidebar's data comes from `AlkimWeb.Nav`, mounted as a hook on every
  LiveView, so pages only pass what they alone know: which project is open
  and which of its sessions to list.
  """
  use AlkimWeb, :html

  import AlkimWeb.SessionComponents, only: [status: 1]

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders the shell around a page.

      <Layouts.app flash={@flash} nav={@nav} active={:projects}>
        …
      </Layouts.app>
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :active, :atom, default: nil, doc: ":projects | :sessions | :new | :providers"
  attr :nav, :map, required: true, doc: "sidebar data assigned by `AlkimWeb.Nav`"
  attr :project, :any, default: nil, doc: "the project being viewed, if any"
  attr :sessions, :list, default: [], doc: "sidebar entries for the open project"
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="a-app">
      <header class="a-topbar">
        <.link navigate={~p"/"} class="a-brand">
          <span class="a-brand-mark">⟁</span>
          <span>Alkim</span>
        </.link>

        <nav class="a-pills" aria-label="Main">
          <.link navigate={~p"/"} aria-current={@active == :projects && "page"}>Projects</.link>
          <.link navigate={~p"/sessions"} aria-current={@active == :sessions && "page"}>
            Sessions
          </.link>
        </nav>

        <div class="a-topbar-right">
          <.link
            navigate={~p"/providers"}
            class="a-icon-btn"
            title="Provider profiles"
            aria-current={@active == :providers && "page"}
          >
            <.icon name="hero-server-stack" class="size-4" />
          </.link>
          <span class="a-runtime" title="LiveView connection to the local runtime">
            <span class="a-dot"></span>
            <span class="a-runtime-online">Runtime</span>
            <span class="a-runtime-offline">Connecting…</span>
          </span>
        </div>
      </header>

      <div class="a-body">
        <aside class="a-side">
          <div class="a-side-head">
            <span class="a-h2">Projects</span>
            <.link navigate={~p"/?add=1"} class="a-icon-btn" title="Add a project">
              <.icon name="hero-plus" class="size-4" />
            </.link>
          </div>

          <nav class="a-side-list">
            <p :if={@nav.projects == []} class="a-side-empty">No projects yet.</p>
            <.link
              :for={p <- @nav.projects}
              navigate={~p"/projects/#{p.id}"}
              id={"nav-project-#{p.id}"}
              class={["a-side-item", @project && @project.id == p.id && "a-side-item-on"]}
            >
              <.icon name="hero-folder" class="size-4 a-faint" />
              <span class="a-truncate">{p.name}</span>
              <span :if={@nav.active_counts[p.id]} class="a-badge">{@nav.active_counts[p.id]}</span>
            </.link>
          </nav>

          <div :if={@project && @sessions != []} class="a-side-section">
            <span class="a-h2">{@project.name}</span>
            <.link
              :for={entry <- @sessions}
              navigate={entry.path}
              id={"nav-entry-#{entry.id}"}
              class="a-side-entry"
            >
              <span class="a-truncate">{entry.title}</span>
              <.status status={entry.status} />
            </.link>
          </div>

          <div class="a-side-foot">
            <span class="a-h2">Harnesses</span>
            <span :for={h <- @nav.harnesses} class="a-side-harness" title={h.executable || h.name}>
              <span class={["a-dot", harness_dot(h.status)]}></span>
              <span class="a-truncate">{h.name}</span>
            </span>
          </div>
        </aside>

        <main class="a-main">
          {render_slot(@inner_block)}
        </main>
      </div>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  defp harness_dot(:available), do: "a-dot-on"
  defp harness_dot(:no_adapter), do: "a-dot-partial"
  defp harness_dot(:not_installed), do: "a-dot-off"

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
