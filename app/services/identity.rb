class Identity
  attr_reader :name, :roles
  def initialize(name:, roles:)
    @name = name.to_s
    @roles = Array(roles) & AreaConfiguration.roles
  end
  def areas = AreaConfiguration.ids.select { |area| reader?(area) }
  def audit_areas = AreaConfiguration.ids.select { |area| roles.include?("#{area}_auditor") }
  def auditor? = audit_areas.any?
  def reader?(area) = roles.include?("#{area}_reader") || writer?(area)
  def writer?(area) = roles.include?("#{area}_writer")
  def any_writer? = areas.any? { |area| writer?(area) }
  def export?(area) = writer?(area)
  def export_key?(area) = writer?(area) && roles.include?("#{area}_key_exporter")
  def any_key_exporter? = areas.any? { |area| export_key?(area) }
end
