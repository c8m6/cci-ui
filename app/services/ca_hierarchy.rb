# frozen_string_literal: true

# Projects verified issuer edges into a deterministic forest, showing each CA once.
class CaHierarchy
  def initialize(authorities)
    @entries = authorities.sort_by { |entry| [entry.fetch("subject"), entry.fetch("fingerprint")] }
    @by_fingerprint = @entries.index_by { |entry| entry.fetch("fingerprint") }
    @children = Hash.new { |hash, key| hash[key] = [] }
    @entries.each do |entry|
      next if entry.fetch("kind") == "root"

      issuers(entry).each { |fingerprint| @children[fingerprint] << entry }
    end
    @seen = Set.new
  end

  def groups
    rooted = @entries.select { |entry| entry.fetch("kind") == "root" }.map { |entry| branch(entry) }
    unresolved = []
    # Start disconnected chains at their missing issuer before handling cycles.
    @entries.select { |entry| issuers(entry).empty? }.each { |entry| append_unseen(unresolved, entry) }
    @entries.each { |entry| append_unseen(unresolved, entry) }
    { rooted: rooted, unresolved: unresolved }
  end

  private

  def issuers(entry)
    entry.fetch("issuer_fingerprints", []).uniq.select { |fingerprint| @by_fingerprint.key?(fingerprint) }
  end

  def append_unseen(groups, entry)
    groups << branch(entry) unless @seen.include?(entry.fetch("fingerprint"))
  end

  def branch(entry)
    rows = []
    stack = [{ entry: entry, depth: 0 }]
    until stack.empty?
      row = stack.pop
      fingerprint = row.fetch(:entry).fetch("fingerprint")
      next unless @seen.add?(fingerprint)

      rows << row
      @children[fingerprint].reverse_each do |child|
        stack << { entry: child, depth: row.fetch(:depth) + 1 }
      end
    end
    { root: entry, rows: rows }
  end
end
