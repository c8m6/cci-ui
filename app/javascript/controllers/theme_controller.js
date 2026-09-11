import { Controller } from "@hotwired/stimulus"
export default class extends Controller {
  static targets = ["button"]
  buttonTargetConnected() {
    if (this.element.dataset.theme) this.apply(this.element.dataset.theme)
  }
  connect() {
    let saved
    try { saved = localStorage.getItem("cci-theme") } catch (_) { /* storage may be disabled */ }
    this.apply(saved || (matchMedia("(prefers-color-scheme: dark)").matches ? "slate" : "default"))
  }
  toggle() {
    const theme = this.element.dataset.theme === "slate" ? "default" : "slate"
    this.apply(theme)
    try { localStorage.setItem("cci-theme", theme) } catch (_) { /* keep in-memory preference */ }
  }
  apply(theme) {
    this.element.dataset.theme = theme
    this.buttonTarget.textContent = theme === "slate" ? "☀" : "☾"
    const label = theme === "slate" ? "Helles Farbschema verwenden" : "Dunkles Farbschema verwenden"
    this.buttonTarget.setAttribute("aria-label", label)
    this.buttonTarget.title = label
    this.buttonTarget.setAttribute("aria-pressed", String(theme === "slate"))
  }
}
