defmodule KhymeiaWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use KhymeiaWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :active, :atom, default: nil, doc: "the active nav item (:dashboard | :new | :providers)"
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="k-shell">
      <header class="k-topbar">
        <.link navigate={~p"/"} class="k-brand">
          <span class="k-brand-mark">⟁</span>
          <span>Khymeia</span>
        </.link>
        <nav class="k-nav">
          <.link navigate={~p"/"} aria-current={@active == :dashboard && "page"}>Sessions</.link>
          <.link navigate={~p"/sessions/new"} aria-current={@active == :new && "page"}>
            New session
          </.link>
          <.link navigate={~p"/providers"} aria-current={@active == :providers && "page"}>
            Providers
          </.link>
          <span class="k-runtime" title="LiveView connection to the local runtime">
            <span class="k-dot"></span>
            <span class="k-runtime-online">Runtime online</span>
            <span class="k-runtime-offline">Connecting…</span>
          </span>
        </nav>
      </header>

      <main>
        {render_slot(@inner_block)}
      </main>
    </div>

    <.flash_group flash={@flash} />
    """
  end

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
