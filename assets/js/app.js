// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/alkim"
import topbar from "../vendor/topbar"
import {Terminal} from "../vendor/xterm"
import {FitAddon} from "../vendor/xterm-addon-fit"

// Theme preference is shared across tabs; system colors remain the default.
const themeMedia = matchMedia("(prefers-color-scheme: dark)")
const applyTheme = theme => {
  document.documentElement.dataset.theme = theme || (themeMedia.matches ? "dark" : "light")
  window.dispatchEvent(new Event("alkim:theme-changed"))
}
let savedTheme
try { savedTheme = localStorage.getItem("phx:theme") } catch (_) { /* Storage can be unavailable. */ }
applyTheme(savedTheme)
window.addEventListener("alkim:toggle-theme", () => {
  savedTheme = document.documentElement.dataset.theme === "dark" ? "light" : "dark"
  try { localStorage.setItem("phx:theme", savedTheme) } catch (_) { /* Keep the current tab usable. */ }
  applyTheme(savedTheme)
})
window.addEventListener("storage", e => {
  if (e.key === "phx:theme") { savedTheme = e.newValue; applyTheme(savedTheme) }
})
themeMedia.addEventListener("change", () => { if (!savedTheme) applyTheme() })
window.addEventListener("keydown", e => {
  if (e.key === "Escape") {
    document.getElementById("app-sidebar")?.classList.remove("a-side-open")
    document.getElementById("sidebar-toggle")?.setAttribute("aria-expanded", "false")
  }
})

// Renders the time elapsed since data-since (ISO 8601) and ticks locally.
// Purely presentational: no requests are made to the runtime.
const Elapsed = {
  mounted() { this.tick(); this.timer = setInterval(() => this.tick(), 1000) },
  updated() { this.tick() },
  destroyed() { clearInterval(this.timer) },
  tick() {
    const since = Date.parse(this.el.dataset.since)
    const until = this.el.dataset.until ? Date.parse(this.el.dataset.until) : Date.now()
    if (Number.isNaN(since)) return
    const total = Math.max(0, Math.floor((until - since) / 1000))
    const h = Math.floor(total / 3600), m = Math.floor((total % 3600) / 60), s = total % 60
    const pad = n => String(n).padStart(2, "0")
    this.el.textContent = h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${pad(m)}:${pad(s)}`
  },
}

// Keeps a scroll container pinned to the bottom unless the user scrolled up.
const FollowTail = {
  mounted() {
    this.pinned = true
    this.el.addEventListener("scroll", () => {
      this.pinned = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 40
    })
    this.el.scrollTop = this.el.scrollHeight
  },
  updated() { if (this.pinned) this.el.scrollTop = this.el.scrollHeight },
}

// Cmd/Ctrl+Enter submits the enclosing form.
const SubmitOnMetaEnter = {
  mounted() {
    this.el.addEventListener("keydown", e => {
      if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
        e.preventDefault()
        this.el.form?.requestSubmit()
      }
    })
  },
}


// An embedded terminal. The runtime owns the pseudo-terminal and sends raw
// bytes; this only paints them and reports the window size back, so the TUI
// lays itself out for what the user can actually see. Output is base64 so
// that a byte sequence which is not valid UTF-8 cannot break the channel.
const EmbeddedTerminal = {
  mounted() {
    const styles = getComputedStyle(document.documentElement)
    const color = name => styles.getPropertyValue(name).trim()

    this.term = new Terminal({
      allowProposedApi: true,
      convertEol: false,
      cursorBlink: true,
      fontFamily: styles.getPropertyValue("--a-mono").trim() || "monospace",
      fontSize: 13,
      scrollback: 5000,
      theme: {background: color("--a-sunken"), foreground: color("--a-text"), cursor: color("--a-accent")},
    })

    this.onThemeChange = () => {
      const styles = getComputedStyle(document.documentElement)
      const color = name => styles.getPropertyValue(name).trim()
      this.term.options.theme = {background: color("--a-sunken"), foreground: color("--a-text"), cursor: color("--a-accent")}
    }
    window.addEventListener("alkim:theme-changed", this.onThemeChange)
    this.fit = new FitAddon()
    this.term.loadAddon(this.fit)
    this.term.open(this.el)

    this.term.onData(data => this.pushEvent("terminal_keys", {data}))

    this.handleEvent("terminal:write", ({id, data, reset}) => {
      if (id !== this.el.dataset.terminalId) return
      // A replay carries the whole scrollback, so start from a clean screen
      // rather than appending it to what is already painted.
      if (reset) this.term.reset()
      if (data) this.term.write(Uint8Array.from(atob(data), c => c.charCodeAt(0)))
    })

    // The window drives the size, so refit whenever the pane changes.
    this.observer = new ResizeObserver(() => this.refit())
    this.observer.observe(this.el)
    this.refit()
    this.term.focus()
    this.pushEvent("terminal_attached", {})
  },

  refit() {
    if (this.el.clientHeight === 0) return
    this.fit.fit()
    const {rows, cols} = this.term
    if (rows === this.rows && cols === this.cols) return
    this.rows = rows
    this.cols = cols
    this.pushEvent("terminal_resize", {rows, cols})
  },

  destroyed() {
    window.removeEventListener("alkim:theme-changed", this.onThemeChange)
    this.observer?.disconnect()
    this.term?.dispose()
  },
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, Elapsed, EmbeddedTerminal, FollowTail, SubmitOnMetaEnter},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#4ebca5"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

