# frozen_string_literal: true

# A public-certificate projection, scoped to the same areas as the catalogue.
class CaInventory < ApplicationRecord
  def self.enabled?
    %w[true 1].include?(ENV.fetch("CCI_CA_INVENTORY_ENABLED", "false").strip.downcase)
  end

  def current_authorities(now = Time.current)
    authorities.select do |entry|
      Time.iso8601(entry.fetch("not_before")) <= now && Time.iso8601(entry.fetch("not_after")) > now
    end
  end

  def hierarchy
    CaHierarchy.new(authorities).groups
  end

  def hiera
    current_authorities.select { |entry| entry.fetch("referenceable", true) }.map { |entry| entry.fetch("hiera") }.uniq.to_yaml
  end
end
