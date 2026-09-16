module ApplicationHelper
  def area_label(area) = AreaConfiguration.label(area)
  def filter_params = params.permit(:q, :area, :source, :status, :rollout_status, :key, :sort, :history, :archived).to_h
  def date_label(time) = time&.strftime("%d.%m.%Y") || "–"
  def puppetdb_enabled? = PuppetdbConfiguration.enabled?
  def puppetdb_fingerprint_missing?(certificate)
    certificate.public_send(PuppetdbConfiguration.new.fingerprint_column).nil?
  end
  def icon(name)
    paths = {
      "shield" => '<path d="M12 3 4 6v6c0 5 8 9 8 9s8-4 8-9V6z"/><path d="m8 12 3 3 5-6"/>',
      "search" => '<circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 5 5"/>',
      "upload" => '<path d="M12 16V3m-5 5 5-5 5 5M4 15v5h16v-5"/>',
      "arrow" => '<path d="M5 12h14m-5-5 5 5-5 5"/>',
      "key" => '<circle cx="8" cy="8" r="4"/><path d="m11 11 9 9m-5-5 3-3m0 6 3-3"/>',
      "grid" => '<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/>'
    }
    tag.svg(paths.fetch(name, paths["shield"]).html_safe, viewBox: "0 0 24 24", fill: "none", stroke: "currentColor", "stroke-width": 1.6, "aria-hidden": true, class: "icon")
  end
end
