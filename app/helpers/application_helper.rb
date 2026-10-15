# frozen_string_literal: true

# Formats catalogue labels and navigation while keeping literal audit data intact.
module ApplicationHelper
  def ca_validity_badge(entry)
    return unless entry["not_before"] && entry["not_after"]

    certificate = Certificate.new(not_before: entry.fetch("not_before"), not_after: entry.fetch("not_after"))
    tag.span(certificate.status, class: "badge #{certificate.status_class}")
  end

  def area_label(area) = AreaConfiguration.label(area)
  def filter_params = params.permit(:q, :area, :source, :status, :rollout_status, :key, :sort, :history, :archived).to_h
  def date_label(time) = time ? l(time.to_date) : "–"

  def locale_return_path
    return root_path if @error_status
    return import_preview_path(token: @token) if controller_name == "imports" && @preview && @token
    return request.fullpath if request.get?

    controller_name == "imports" ? new_import_path : root_path
  end

  def audit_comment(event)
    comment = event.details["comment"]
    # Translate only the application's fixed message, never external audit data.
    originals = %i[de en].map { |locale| I18n.t("audit.archive_comment", locale: locale) }
    originals.include?(comment) ? t("audit.archive_comment") : comment
  end

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
      "github" => '<path d="M9 19c-4.3 1.3-4.3-2.4-6-3m12 6v-3.9a3.4 3.4 0 0 0-.9-2.7c3-.3 6.2-1.5 6.2-6.7A5.2 5.2 0 0 0 19 5.1a4.8 4.8 0 0 0-.1-3.6S17.8 1.2 15.2 3A13 13 0 0 0 8.8 3C6.2 1.2 5.1 1.5 5.1 1.5A4.8 4.8 0 0 0 5 5.1 5.2 5.2 0 0 0 3.7 8.7c0 5.2 3.2 6.4 6.2 6.7a3.4 3.4 0 0 0-.9 2.7V22" />',
      "grid" => '<rect x="3" y="3" width="7" height="7" rx="1"/>' \
                '<rect x="14" y="3" width="7" height="7" rx="1"/>' \
                '<rect x="3" y="14" width="7" height="7" rx="1"/>' \
                '<rect x="14" y="14" width="7" height="7" rx="1"/>'
    }
    tag.svg(paths.fetch(name, paths["shield"]).html_safe, viewBox: "0 0 24 24", fill: "none", stroke: "currentColor",
      "stroke-width": 1.6, "aria-hidden": true, class: "icon")
  end
end
