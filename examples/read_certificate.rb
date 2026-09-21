#!/usr/bin/env ruby
# Standalone reader. Each call resolves the certid again, then keeps all fields
# on the same version even if another client publishes a renewal in between.
require_relative "../lib/cci_client"
require_relative "../lib/area_secrets"

module CertificateReadExample
  def self.read(area:, certid:, version: nil, private_key: false, include_chain: false,
    prefix: ENV.fetch("CONSUL_PREFIX", "cci"), connection: ConsulConnection.new)
    keys = private_key ? { area => AreaSecrets.fetch(area) } : {}
    reader = CciClient.new(url: ENV.fetch("CONSUL_URL", "http://127.0.0.1:8500"),
      prefix: prefix, connection: connection, keys: keys)
    selection = { area: area, certid: certid, version: version }
    result = {
      "metadata" => reader.fetch(**selection, field: "metadata"),
      "certificate" => reader.fetch(**selection)
    }
    result["chain"] = reader.fetch(**selection, field: "chain") if include_chain
    result["private_key"] = reader.fetch(**selection, field: "private_key") if private_key
    result
  end
end

if $PROGRAM_NAME == __FILE__
  abort "Usage: ruby examples/read_certificate.rb AREA CERTID [VERSION]" unless (2..3).cover?(ARGV.size)
  area, certid, version = ARGV
  puts JSON.pretty_generate(CertificateReadExample.read(area: area, certid: certid, version: version && Integer(version, 10)))
end
