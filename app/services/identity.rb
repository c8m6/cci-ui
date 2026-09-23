# frozen_string_literal: true

# Interprets area roles independently of the authentication provider.
class Identity
  attr_reader :name, :roles

  def initialize(name:, roles:)
    @name = name.to_s
    @roles = Array(roles) & AreaConfiguration.roles
  end

  def areas = AreaConfiguration.ids.select { |area| reader?(area) }
  def audit_areas = AreaConfiguration.ids.select { |area| roles.include?("#{area}_auditor") }
  def auditor? = audit_areas.any?
  def reader?(area) = roles.include?("#{area}_reader") || writer?(area) || key_exporter?(area)
  def writer?(area) = roles.include?("#{area}_writer")
  def any_writer? = areas.any? { |area| writer?(area) }
  def key_exporter?(area) = roles.include?("#{area}_key_exporter")
  def export?(area) = writer?(area) || key_exporter?(area)
  def export_key?(area) = key_exporter?(area)
  def any_export? = areas.any? { |area| export?(area) }
  def any_exporter? = areas.any? { |area| key_exporter?(area) }
end
