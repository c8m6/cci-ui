# frozen_string_literal: true

require "base64"

# A permission-scoped SQL projection of existing observations, not another host inventory.
class PuppetdbHosts
  PAGE_SIZE = 30

  def self.identifier(name) = Base64.urlsafe_encode64(name, padding: false)

  def self.certname(identifier)
    raise ActiveRecord::RecordNotFound unless identifier.to_s.match?(/\A[A-Za-z0-9_-]{1,5462}\z/)

    name = Base64.urlsafe_decode64(identifier).force_encoding(Encoding::UTF_8)
    raise ActiveRecord::RecordNotFound unless name.valid_encoding? && name.match?(/\A[^\s\p{Cntrl}]{1,1024}\z/)

    name
  rescue ArgumentError
    raise ActiveRecord::RecordNotFound
  end

  def initialize(identity, area: nil)
    @records = Certificate.visible_to(identity)
    @records = @records.where(area: area) if area.present?
  end

  def certificates(name)
    @records.where("puppetdb_hosts @> ?::jsonb", JSON.generate([name]))
  end

  def list(query: "", sync: nil, page: 1)
    relation = @records.joins("CROSS JOIN LATERAL jsonb_array_elements_text(puppetdb_hosts) AS observed_host(name)")
    relation = relation.where("observed_host.name ILIKE ?", "%#{Certificate.sanitize_sql_like(query.to_s.strip)}%")
    stale = Arel::Nodes::NamedFunction.new("BOOL_OR", [stale_condition])
    relation = relation.group("observed_host.name").select(
      "observed_host.name AS certname, COUNT(*) AS certificate_count, MIN(puppetdb_checked_at) AS checked_at",
      stale.as("stale")
    )
    relation = relation.having(Arel::Nodes::NamedFunction.new("BOOL_OR", [stale_condition]).eq(sync == "stale")) if %w[current
      stale].include?(sync)
    total = Certificate.connection.select_value("SELECT COUNT(*) FROM (#{relation.to_sql}) AS host_counts").to_i
    pages = [(total / PAGE_SIZE.to_f).ceil, 1].max
    page = page.to_i.clamp(1, pages)
    rows = Certificate.connection.select_all(relation.order("observed_host.name").offset((page - 1) * PAGE_SIZE).limit(PAGE_SIZE)).to_a
    { rows: rows, total: total, page: page, pages: pages }
  end

  def summary(name)
    records = certificates(name)
    raise ActiveRecord::RecordNotFound unless records.exists?

    { total: records.count, checked_at: records.minimum(:puppetdb_checked_at), stale: records.where(stale_condition).exists? }
  end

  private

  def stale_condition
    columns = Certificate.arel_table
    columns[:puppetdb_error_at].not_eq(nil).or(columns[:puppetdb_checked_at].eq(nil))
                               .or(columns[PuppetdbConfiguration.new.fingerprint_column].eq(nil))
  end
end
