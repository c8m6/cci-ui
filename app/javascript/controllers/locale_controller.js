import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["destination"]
  static values = { followLocation: Boolean }

  prepare() {
    // Turbo frame searches change the URL without replacing the language form.
    // POST-rendered previews must retain their server-provided GET destination.
    if (this.followLocationValue) {
      this.destinationTarget.value = window.location.pathname + window.location.search + window.location.hash
    }
  }
}
