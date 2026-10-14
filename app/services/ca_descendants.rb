# frozen_string_literal: true

# Uses the inventory's verified graph; no network requests or guessed name edges.
class CaDescendants
  PAGE_SIZE = 20
  attr_reader :inventory, :page, :pages, :total, :records, :depths, :scope

  def initialize(record, identity:, page: 1, scope: "direct")
    @records = []
    @total = 0
    @scope = scope == "all" ? "all" : "direct"
    return unless CaInventory.enabled?

    @inventory = CaInventory.find_by(area: record.area)
    return unless inventory&.authorities&.any? { |entry| entry.fetch("fingerprint") == record.fingerprint }

    @depths = descendant_depths(record.fingerprint)
    candidates = Certificate.visible_to(identity).where(area: record.area, fingerprint: depths.keys)
                            .where.not(source: "filesystem", filesystem_missing_scans: 1..)
    @total = candidates.distinct.count(:fingerprint)
    @pages = [(@total / PAGE_SIZE.to_f).ceil, 1].max
    @page = page.to_i.clamp(1, pages)
    @records = candidates.select("DISTINCT ON (fingerprint) certificates.*")
                         .order(:fingerprint, active: :desc, source: :asc, id: :asc).offset((@page - 1) * PAGE_SIZE).limit(PAGE_SIZE)
  end

  def kind(record)
    inventory.authorities.find { |entry| entry.fetch("fingerprint") == record.fingerprint }&.fetch("kind") || "certificate"
  end

  def ambiguous?(record)
    inventory.issuer_edges.fetch(record.fingerprint, []).size > 1
  end

  private

  def descendant_depths(root)
    children = Hash.new { |hash, key| hash[key] = [] }
    inventory.issuer_edges.each { |child, parents| parents.each { |parent| children[parent] << child } }
    depths = { root => 0 }
    queue = [root]
    offset = 0
    while offset < queue.size
      parent = queue[offset]
      offset += 1
      next if depths[parent] >= (scope == "all" ? CciClient::MAX_CHAIN_ISSUERS : 1)

      children[parent].each do |child|
        next if depths.key?(child)

        depths[child] = depths[parent] + 1
        queue << child
      end
    end
    depths.except(root)
  end
end
