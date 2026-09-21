defmodule AlkimWeb.Layouts do
  @moduledoc """
  The application shell: a slim top bar, a sidebar listing the projects (and
  the sessions of the one being viewed) and the page itself.

  The sidebar's data comes from `AlkimWeb.Nav`, mounted as a hook on every
  LiveView, so pages only pass what they alone know: which project is open
  and which of its sessions to list.
  """
  use AlkimWeb, :html

  import AlkimWeb.SessionComponents, only: [status: 1, kind_icon: 1]

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
  attr :sessions, :list, default: [], doc: "what is inside the thing being viewed"

  attr :sessions_title, :string,
    default: nil,
    doc: "heading for that list (default: project name)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <a href="#main-content" class="a-skip-link">Skip to content</a>
    <div class="a-app">
      <header class="a-topbar">
        <div class="a-brand-area">
          <.link navigate={~p"/"} class="a-brand" aria-label="Alkim home">
            <img src={~p"/images/alkim-mark-180.png"} alt="" class="a-brand-mark" />
            <span>alkim<span class="a-brand-period">.</span></span>
          </.link>
          <button
            id="sidebar-toggle"
            class="a-icon-btn a-sidebar-toggle"
            type="button"
            aria-label="Toggle navigation"
            aria-controls="app-sidebar"
            aria-expanded="true"
            phx-hook="SidebarToggle"
            phx-update="ignore"
            title="Toggle navigation"
          >
            <.icon name="panel-left" class="size-5" />
          </button>
        </div>
        <div class="a-topbar-context">
          <.icon name="hero-square-3-stack-3d" class="size-4" />
          <span>Workspace</span><span class="a-faint">/</span>
          <span class="a-truncate">{if @project, do: @project.name, else: page_label(@active)}</span>
        </div>
        <div class="a-topbar-right">
          <span class="a-runtime" title="LiveView connection to the local runtime">
            <span class="a-dot"></span>
            <span class="a-runtime-online">Local runtime</span>
            <span class="a-runtime-offline">Connecting…</span>
          </span>
          <button
            id="theme-toggle"
            class="a-icon-btn"
            type="button"
            phx-click={JS.dispatch("alkim:toggle-theme")}
            aria-label="Toggle color theme"
            title="Toggle color theme"
          >
            <.icon name="hero-sun" class="size-4 a-theme-sun" />
            <.icon name="hero-moon" class="size-4 a-theme-moon" />
          </button>
        </div>
      </header>
      <button
        id="sidebar-backdrop"
        class="a-sidebar-backdrop"
        type="button"
        aria-label="Close navigation"
        tabindex="-1"
      ></button>
      <div class="a-body">
        <aside class="a-side" id="app-sidebar">
          <nav class="a-side-nav" aria-label="Main">
            <span class="a-eyebrow">Workspace</span>
            <.link
              navigate={~p"/"}
              class="a-nav-link"
              aria-label="Projects"
              title="Projects"
              aria-current={@active == :projects && "page"}
            >
              <.icon name="hero-squares-2x2" class="size-4" /><span class="a-nav-label">Projects</span>
              <span class="a-nav-count">{length(@nav.projects)}</span>
            </.link>
            <.link
              navigate={~p"/sessions"}
              class="a-nav-link"
              aria-label="Sessions"
              title="Sessions"
              aria-current={@active == :sessions && "page"}
            >
              <.icon name="hero-command-line" class="size-4" /><span class="a-nav-label">Sessions</span>
            </.link>
            <.link
              navigate={~p"/providers"}
              class="a-nav-link"
              aria-label="Providers"
              title="Providers"
              aria-current={@active == :providers && "page"}
            >
              <.icon name="hero-server-stack" class="size-4" /><span class="a-nav-label">Providers</span>
            </.link>
            <.link
              navigate={~p"/sessions/new"}
              id="sidebar-new-session"
              class="a-btn a-side-create"
              aria-label="New session"
              title="New session"
            >
              <.icon name="hero-plus" class="size-4" /><span class="a-nav-label">New session</span>
              <.icon name="hero-arrow-up-right" class="size-3.5" />
            </.link>
          </nav>
          <div class="a-side-scroll">
            <div class="a-side-head">
              <span class="a-eyebrow">Your projects</span>
              <.link
                navigate={~p"/?add=1"}
                class="a-icon-btn"
                title="Add a project"
                aria-label="Add a project"
              >
                <.icon name="hero-plus" class="size-4" />
              </.link>
            </div>
            <nav class="a-side-list" aria-label="Projects">
              <p :if={@nav.projects == []} class="a-side-empty">Your next idea starts here.</p>
              <.link
                :for={p <- @nav.projects}
                navigate={~p"/projects/#{p.id}"}
                id={"nav-project-#{p.id}"}
                aria-label={p.name}
                title={p.name}
                aria-current={@project && @project.id == p.id && "page"}
                class={["a-side-item", @project && @project.id == p.id && "a-side-item-on"]}
              >
                <.icon name="hero-folder" class="size-4" />
                <span class="a-truncate">{p.name}</span>
                <span :if={@nav.active_counts[p.id]} class="a-badge">{@nav.active_counts[p.id]}</span>
              </.link>
            </nav>
            <div :if={@project && @sessions != []} class="a-side-section">
              <span class="a-eyebrow">{@sessions_title || "Project activity"}</span>
              <.link
                :for={entry <- @sessions}
                navigate={entry.path}
                id={"nav-entry-#{entry.id}"}
                aria-label={"#{entry.title} · #{entry.status}"}
                title={"#{entry.title} · #{entry.status}"}
                class="a-side-entry"
              >
                <.icon name={kind_icon(entry.kind)} class="size-3.5 a-faint" />
                <span class="a-truncate">{entry.title}</span>
                <.status status={entry.status} />
              </.link>
            </div>
          </div>
          <div class="a-side-foot">
            <div class="a-side-foot-head">
              <span class="a-eyebrow">Agent harnesses</span><span class="a-mono a-faint">{Enum.count(
                @nav.harnesses,
                &(&1.status == :available)
              )} ready</span>
            </div>
            <span
              :for={h <- Enum.filter(@nav.harnesses, &(&1.status in [:available, :no_adapter]))}
              class="a-side-harness"
              title={h.executable || h.name}
            >
              <span class={["a-dot", harness_dot(h.status)]}></span><span class="a-truncate">{h.name}</span>
            </span>
            <div class="a-local-note">
              <.icon name="hero-computer-desktop" class="size-3.5" />
              On your machine. In your control.
            </div>
          </div>
        </aside>
        <main class="a-main" id="main-content" tabindex="-1">
          {render_slot(@inner_block)}
        </main>
      </div>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  defp page_label(:projects), do: "Projects"
  defp page_label(:sessions), do: "Sessions"
  defp page_label(:providers), do: "Providers"
  defp page_label(:new), do: "New session"
  defp page_label(_), do: "Activity"

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
