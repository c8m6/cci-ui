#!/usr/bin/env ruby
# Standalone writer. Each invocation creates an integer version, even when
# uploading the same certificate again. Publish CA certificates separately.
require_relative "../lib/cci_writer"

module CertificateExample
  def self.add(area:, certid:, cert:, key: nil, tags: [], client: "puppet", actor: nil,
    prefix: ENV.fetch("CONSUL_PREFIX", "cci"), connection: ConsulConnection.new, encryption_key: nil)
    CciWriter.new(connection: connection, prefix: prefix).save(area: area, certid: certid,
      cert: cert, key: key, tags: tags, client: client, actor: actor, encryption_key: encryption_key)
  end
end

if $PROGRAM_NAME == __FILE__
  abort "Usage: ruby examples/add_certificate.rb AREA CERTID CERT.pem [KEY.pem]" unless (3..4).cover?(ARGV.size)
  area, certid, cert_path, key_path = ARGV
  cert = OpenSSL::X509::Certificate.new(File.binread(cert_path))
  key = key_path && OpenSSL::PKey.read(File.binread(key_path), ENV["KEY_PASSWORD"])
  puts CertificateExample.add(area: area, certid: certid, cert: cert, key: key,
    client: ENV.fetch("CCI_CLIENT_ID", "puppet"), actor: ENV["CCI_ACTOR"])
end
