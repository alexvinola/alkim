// Keep the desktop rail preference across LiveView navigation and reloads.
const storageKey = "alkim:sidebar-collapsed"
let collapsed = false
try { collapsed = localStorage.getItem(storageKey) === "true" } catch (_) { /* Optional storage. */ }
document.documentElement.dataset.sidebar = collapsed ? "collapsed" : "expanded"

export const SidebarToggle = {
  mounted() {
    this.mobile = matchMedia("(max-width: 600px)")
    this.mobileOpen = false
    this.hovered = false
    this.sidebar = document.getElementById("app-sidebar")
    this.render = () => {
      const desktopExpanded = !collapsed || this.hovered
      const expanded = this.mobile.matches ? this.mobileOpen : desktopExpanded
      document.documentElement.dataset.sidebar = desktopExpanded ? "expanded" : "collapsed"
      document.documentElement.dataset.sidebarMobile = this.mobileOpen ? "open" : "closed"
      const sidebar = document.getElementById("app-sidebar")
      if (sidebar) sidebar.inert = this.mobile.matches && !this.mobileOpen
      this.el.setAttribute("aria-expanded", String(expanded))
      this.el.setAttribute("aria-label", expanded ? "Collapse navigation" : "Expand navigation")
      this.el.title = expanded ? "Collapse navigation" : "Expand navigation"
    }
    this.toggle = () => {
      if (this.mobile.matches) {
        this.mobileOpen = !this.mobileOpen
      } else {
        collapsed = !collapsed
        try { localStorage.setItem(storageKey, String(collapsed)) } catch (_) { /* Keep working without storage. */ }
      }
      this.render()
    }
    this.close = (restoreFocus = false) => {
      if (!this.mobileOpen) return
      this.mobileOpen = false
      if (restoreFocus) this.el.focus()
      this.render()
    }
    this.onKey = e => {
      if (e.key === "Escape" && this.mobileOpen) {
        e.preventDefault()
        this.close(true)
      }
    }
    this.onClick = e => {
      if (!this.mobile.matches || !this.mobileOpen || this.el.contains(e.target)) return
      const sidebar = document.getElementById("app-sidebar")
      if (!sidebar?.contains(e.target) || e.target.closest("a")) this.close(e.target.id === "sidebar-backdrop")
    }
    // Hover previews the full menu without changing the saved rail preference.
    this.onPointerEnter = e => {
      if (this.mobile.matches || e.pointerType === "touch") return
      this.hovered = true
      this.render()
    }
    this.onPointerLeave = () => {
      this.hovered = false
      this.render()
    }
    this.onResize = () => { this.hovered = false; this.close(); this.render() }
    this.onStorage = e => {
      if (e.key !== storageKey && e.key !== null) return
      collapsed = e.newValue === "true"
      this.render()
    }
    this.el.addEventListener("click", this.toggle)
    this.sidebar?.addEventListener("pointerenter", this.onPointerEnter)
    this.sidebar?.addEventListener("pointerleave", this.onPointerLeave)
    this.sidebar?.addEventListener("pointercancel", this.onPointerLeave)
    document.addEventListener("click", this.onClick)
    document.addEventListener("keydown", this.onKey)
    this.mobile.addEventListener("change", this.onResize)
    window.addEventListener("storage", this.onStorage)
    this.render()
  },
  destroyed() {
    this.el.removeEventListener("click", this.toggle)
    this.sidebar?.removeEventListener("pointerenter", this.onPointerEnter)
    this.sidebar?.removeEventListener("pointerleave", this.onPointerLeave)
    this.sidebar?.removeEventListener("pointercancel", this.onPointerLeave)
    document.removeEventListener("click", this.onClick)
    document.removeEventListener("keydown", this.onKey)
    this.mobile.removeEventListener("change", this.onResize)
    window.removeEventListener("storage", this.onStorage)
  },
}
