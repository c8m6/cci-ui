#!/usr/bin/env ruby
# Standalone reader. Each call resolves the lookup again, then keeps all fields
# on the same version even if another client publishes a renewal in between.
require_relative "../lib/cci_client"
require_relative "../lib/area_secrets"

module CertificateReadExample
  def self.read(area:, lookup:, version: nil, private_key: false,
    prefix: ENV.fetch("CONSUL_PREFIX", "cci/v1"), connection: ConsulConnection.new)
    keys = private_key ? { area => AreaSecrets.fetch(area) } : {}
    reader = CciClient.new(url: ENV.fetch("CONSUL_URL", "http://127.0.0.1:8500"),
      prefix: prefix, connection: connection, keys: keys)
    selection = { area: area, lookup: lookup, version: version }
    result = {
      "metadata" => reader.fetch(**selection, field: "metadata"),
      "certificate" => reader.fetch(**selection),
      "chain" => reader.fetch(**selection, field: "chain")
    }
    result["private_key"] = reader.fetch(**selection, field: "private_key") if private_key
    result
  end
end

if $PROGRAM_NAME == __FILE__
  abort "Usage: ruby examples/read_certificate.rb AREA LOOKUP [VERSION_ID]" unless (2..3).cover?(ARGV.size)
  area, lookup, version = ARGV
  puts JSON.pretty_generate(CertificateReadExample.read(area: area, lookup: lookup, version: version))
end
