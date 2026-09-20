defmodule KhymeiaWeb.Layouts do
  @moduledoc """
  The application shell: a slim top bar, a sidebar listing the projects (and
  the sessions of the one being viewed) and the page itself.

  The sidebar's data comes from `KhymeiaWeb.Nav`, mounted as a hook on every
  LiveView, so pages only pass what they alone know: which project is open
  and which of its sessions to list.
  """
  use KhymeiaWeb, :html

  import KhymeiaWeb.SessionComponents, only: [status: 1]

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
  attr :nav, :map, required: true, doc: "sidebar data assigned by `KhymeiaWeb.Nav`"
  attr :project, :any, default: nil, doc: "the project being viewed, if any"
  attr :sessions, :list, default: [], doc: "sidebar entries for the open project"
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="k-app">
      <header class="k-topbar">
        <.link navigate={~p"/"} class="k-brand">
          <span class="k-brand-mark">⟁</span>
          <span>Khymeia</span>
        </.link>

        <nav class="k-pills" aria-label="Main">
          <.link navigate={~p"/"} aria-current={@active == :projects && "page"}>Projects</.link>
          <.link navigate={~p"/sessions"} aria-current={@active == :sessions && "page"}>
            Sessions
          </.link>
        </nav>

        <div class="k-topbar-right">
          <.link
            navigate={~p"/providers"}
            class="k-icon-btn"
            title="Provider profiles"
            aria-current={@active == :providers && "page"}
          >
            <.icon name="hero-server-stack" class="size-4" />
          </.link>
          <span class="k-runtime" title="LiveView connection to the local runtime">
            <span class="k-dot"></span>
            <span class="k-runtime-online">Runtime</span>
            <span class="k-runtime-offline">Connecting…</span>
          </span>
        </div>
      </header>

      <div class="k-body">
        <aside class="k-side">
          <div class="k-side-head">
            <span class="k-h2">Projects</span>
            <.link navigate={~p"/?add=1"} class="k-icon-btn" title="Add a project">
              <.icon name="hero-plus" class="size-4" />
            </.link>
          </div>

          <nav class="k-side-list">
            <p :if={@nav.projects == []} class="k-side-empty">No projects yet.</p>
            <.link
              :for={p <- @nav.projects}
              navigate={~p"/projects/#{p.id}"}
              id={"nav-project-#{p.id}"}
              class={["k-side-item", @project && @project.id == p.id && "k-side-item-on"]}
            >
              <.icon name="hero-folder" class="size-4 k-faint" />
              <span class="k-truncate">{p.name}</span>
              <span :if={@nav.active_counts[p.id]} class="k-badge">{@nav.active_counts[p.id]}</span>
            </.link>
          </nav>

          <div :if={@project && @sessions != []} class="k-side-section">
            <span class="k-h2">{@project.name}</span>
            <.link
              :for={entry <- @sessions}
              navigate={entry.path}
              id={"nav-entry-#{entry.id}"}
              class="k-side-entry"
            >
              <span class="k-truncate">{entry.title}</span>
              <.status status={entry.status} />
            </.link>
          </div>

          <div class="k-side-foot">
            <span class="k-h2">Harnesses</span>
            <span :for={h <- @nav.harnesses} class="k-side-harness" title={h.executable || h.name}>
              <span class={["k-dot", harness_dot(h.status)]}></span>
              <span class="k-truncate">{h.name}</span>
            </span>
          </div>
        </aside>

        <main class="k-main">
          {render_slot(@inner_block)}
        </main>
      </div>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  defp harness_dot(:available), do: "k-dot-on"
  defp harness_dot(:no_adapter), do: "k-dot-partial"
  defp harness_dot(:not_installed), do: "k-dot-off"

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
