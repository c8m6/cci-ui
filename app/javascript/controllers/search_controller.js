import { Controller } from "@hotwired/stimulus"
export default class extends Controller {
  schedule() { clearTimeout(this.timer); this.timer = setTimeout(() => this.submit(), 400) }
  submit() { clearTimeout(this.timer); this.element.requestSubmit() }
  disconnect() { clearTimeout(this.timer) }
}
