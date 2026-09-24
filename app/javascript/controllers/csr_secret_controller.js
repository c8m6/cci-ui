import { Controller } from "@hotwired/stimulus"

// Remove disclosed secrets before history navigation or Turbo can retain the page.
export default class extends Controller {
  connect() {
    this.clear = () => this.element.querySelectorAll("input").forEach(input => { input.value = ""; input.removeAttribute("value") })
    window.addEventListener("pagehide", this.clear)
    document.addEventListener("turbo:before-cache", this.clear)
    this.timer = setTimeout(this.clear, 60000)
  }

  disconnect() {
    clearTimeout(this.timer)
    window.removeEventListener("pagehide", this.clear)
    document.removeEventListener("turbo:before-cache", this.clear)
    this.clear()
  }
}
