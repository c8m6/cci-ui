# frozen_string_literal: true

# Interprets area roles independently of the authentication provider.
class Identity
  attr_reader :uid, :display_name, :roles
  alias name uid

  def initialize(roles:, uid: nil, name: nil, display_name: nil)
    @uid = (uid || name).to_s
    candidate = display_name.to_s.strip
    @display_name = candidate.empty? ? @uid : candidate
    @roles = Array(roles) & AreaConfiguration.roles
  end

  def areas = AreaConfiguration.ids.select { |area| reader?(area) }
  def audit_areas = AreaConfiguration.ids.select { |area| roles.include?("#{area}_auditor") }
  def csr?(area) = roles.include?("#{area}_csr")
  def csr_areas = AreaConfiguration.ids.select { |area| csr?(area) }
  def any_csr? = csr_areas.any?
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
