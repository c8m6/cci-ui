import { Controller } from "@hotwired/stimulus"

// Each area has an independent tab set, with all panels readable without JS.
export default class extends Controller {
  static targets = ["list", "tab", "panel"]

  connect() {
    if (!this.hasListTarget) return
    this.listTarget.hidden = false
    this.activate(0)
  }

  select(event) {
    this.activate(this.tabTargets.indexOf(event.currentTarget))
  }

  navigate(event) {
    const index = this.tabTargets.indexOf(event.target)
    if (index < 0) return
    const last = this.tabTargets.length - 1
    const destinations = { ArrowLeft: index === 0 ? last : index - 1,
      ArrowRight: index === last ? 0 : index + 1, Home: 0, End: last }
    if (!(event.key in destinations)) return
    event.preventDefault()
    const destination = destinations[event.key]
    this.activate(destination)
    this.tabTargets[destination].focus()
  }

  activate(index) {
    this.tabTargets.forEach((tab, position) => {
      const selected = position === index
      tab.setAttribute("aria-selected", String(selected))
      tab.tabIndex = selected ? 0 : -1
      this.panelTargets[position].hidden = !selected
    })
  }
}
