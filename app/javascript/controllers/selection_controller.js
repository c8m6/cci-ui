import { Controller } from "@hotwired/stimulus"
export default class extends Controller {
  static targets = ["checkbox", "count"]
  static values = { messages: Object }
  toggleAll(event) { this.checkboxTargets.forEach(box => box.checked = event.target.checked); this.update() }
  update() {
    const count = this.checkboxTargets.filter(box => box.checked).length
    const plural = new Intl.PluralRules(document.documentElement.lang).select(count)
    const message = this.messagesValue[plural] || this.messagesValue.other
    this.countTarget.textContent = message.replace("%{count}", String(count))
  }
}
