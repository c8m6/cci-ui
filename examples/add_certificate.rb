#!/usr/bin/env ruby
# frozen_string_literal: true

# Standalone writer. Each invocation creates an integer version, even when
# uploading the same certificate again. Publish CA certificates separately.
require_relative "../lib/cci_writer"

# Runnable standalone writer example using the same CAS and encryption contract as Rails.
module CertificateExample
  def self.add(area:, certid:, cert:, key: nil, tags: [], client: "puppet", actor: nil,
               prefix: nil, connection: nil, encryption_key: nil)
    CciWriter.new(connection: connection, prefix: prefix).save(area: area, certid: certid,
      cert: cert, key: key, tags: tags, client: client, actor: actor, encryption_key: encryption_key)
  end
end

if $PROGRAM_NAME == __FILE__
  abort "Usage: ruby examples/add_certificate.rb AREA CERTID CERT.pem [KEY.pem]" unless (3..4).cover?(ARGV.size)
  area, certid, cert_path, key_path = ARGV
  cert = OpenSSL::X509::Certificate.new(File.binread(cert_path))
  settings = CciConfiguration.current.dig("integrations", "writer")
  password = settings.fetch("key_password")
  key = key_path && OpenSSL::PKey.read(File.binread(key_path), password.empty? ? nil : password)
  puts CertificateExample.add(area: area, certid: certid, cert: cert, key: key,
    client: settings.fetch("client_id"), actor: settings.fetch("actor").empty? ? nil : settings.fetch("actor"))
end
