import { Controller } from "@hotwired/stimulus"
export default class extends Controller {
  static targets = ["checkbox", "count"]
  toggleAll(event) { this.checkboxTargets.forEach(box => box.checked = event.target.checked); this.update() }
  update() { this.countTarget.textContent = `${this.checkboxTargets.filter(box => box.checked).length} ausgewählt` }
}
