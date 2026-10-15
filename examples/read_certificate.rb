#!/usr/bin/env ruby
# frozen_string_literal: true

# Standalone reader. Each call resolves the certid again, then keeps all fields
# on the same version even if another client publishes a renewal in between.
require_relative "../lib/cci_client"
require_relative "../lib/area_secrets"

# Reads public material by default and opts into private-key access explicitly.
module CertificateReadExample
  def self.read(area:, certid:, version: nil, private_key: false, include_chain: false,
                prefix: nil, connection: nil)
    keys = private_key ? { area => AreaSecrets.fetch(area) } : {}
    reader = CciClient.new(prefix: prefix, connection: connection, keys: keys)
    selection = { area: area, certid: certid, version: version }
    result = {
      "metadata" => reader.read_certificate(**selection, field: "metadata"),
      "certificate" => reader.read_certificate(**selection)
    }
    result["chain"] = reader.read_certificate(**selection, field: "chain") if include_chain
    result["private_key"] = reader.read_certificate(**selection, field: "private_key") if private_key
    result
  end
end

if $PROGRAM_NAME == __FILE__
  abort "Usage: ruby examples/read_certificate.rb AREA CERTID [VERSION]" unless (2..3).cover?(ARGV.size)
  area, certid, version = ARGV
  puts JSON.pretty_generate(CertificateReadExample.read(area: area, certid: certid,
    version: version && Integer(version, 10)))
end
