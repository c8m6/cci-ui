import { Controller } from "@hotwired/stimulus"
export default class extends Controller {
  static targets = ["input", "label"]
  over(event) { event.preventDefault(); this.element.classList.add("dragging") }
  leave() { this.element.classList.remove("dragging") }
  drop(event) { event.preventDefault(); this.leave(); this.inputTarget.files = event.dataTransfer.files; this.change() }
  change() { this.labelTarget.textContent = Array.from(this.inputTarget.files).map(file => file.name).join(", ") }
}
