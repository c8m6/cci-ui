import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["value", "status"]
  static values = { success: String, failure: String }

  async copy() {
    try {
      await navigator.clipboard.writeText(this.valueTarget.textContent)
      this.statusTarget.textContent = this.successValue
    } catch {
      this.statusTarget.textContent = this.failureValue
    }
  }
}
