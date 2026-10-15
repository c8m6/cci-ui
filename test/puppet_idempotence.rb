# frozen_string_literal: true

require "English"
require "openssl"
require "json"
require "base64"
require "tmpdir"
require "fileutils"
require "securerandom"
require "etc"
require_relative "../lib/cci_writer"
require_relative "../lib/certificates/error"
require_relative "../lib/certificates/vault"
begin
  source = CciConfiguration.current
  prefix = "cci-idempotence/#{SecureRandom.hex(8)}"
  snapshot = Marshal.load(Marshal.dump(source.instance_variable_get(:@data)))
  snapshot["consul"]["prefix"] = prefix
  snapshot["areas"].each_value { |area| area.delete("consul") }
  config_dir = Dir.mktmpdir("cci-puppet-config-")
  ENV["CCI_CONFIG_FILE"] = File.join(config_dir, "config.yml")
  File.write(ENV.fetch("CCI_CONFIG_FILE"), YAML.dump(snapshot))
  CciConfiguration.instance_variable_set(:@current, CciConfiguration.load_file(ENV.fetch("CCI_CONFIG_FILE")))
  connection = ConsulConnection.new
  certkey = OpenSSL::PKey::RSA.new(2048)
  cert = OpenSSL::X509::Certificate.new
  cert.version = 2
  cert.serial = 1
  cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=puppet.example.test")
  cert.public_key = certkey.public_key
  cert.not_before = Time.now - 3600
  cert.not_after = Time.now + 86_400
  cert.sign(certkey, OpenSSL::Digest.new("SHA256"))
  writer = CciWriter.new(connection: connection, prefix: prefix)
  writer.save(area: "zone_a", certid: "test", cert: cert, key: certkey, client: "puppet")
  Dir.mktmpdir("cci-puppet-") do |dir|
    manifest = File.join(dir, "test.pp")
    File.write(manifest, <<~PUPPET)
      cci::certificate { 'display-name':
        lookup   => 'test',
        area     => 'zone_a',
        path     => '#{dir}/certificate.pem',
        key_path => '#{dir}/key.pem',
        owner    => '#{Etc.getpwuid.name}',
        group    => '#{Etc.getgrgid(Process.gid).name}',
      }
    PUPPET
    command = ["puppet", "apply", "--modulepath", File.expand_path("../integrations/puppet", __dir__),
      "--vardir", "#{dir}/var", "--publicdir", "#{dir}/public", "--ssldir", "#{dir}/ssl",
      "--statedir", "#{dir}/state", "--confdir", "#{dir}/conf", "--logdir", "#{dir}/log",
      "--rundir", "#{dir}/run", "--detailed-exitcodes", manifest]
    system(*command, out: File::NULL)
    first = $CHILD_STATUS.exitstatus
    before = File.mtime("#{dir}/certificate.pem")
    system(*command, out: File::NULL)
    second = $CHILD_STATUS.exitstatus
    after = File.mtime("#{dir}/certificate.pem")
    abort "Idempotence failed #{first}/#{second}" unless first == 2 && second.zero? && before == after
    cert.serial = 2
    cert.sign(certkey, OpenSSL::Digest.new("SHA256"))
    writer.save(area: "zone_a", certid: "test", cert: cert, key: certkey, client: "puppet")
    system(*command, out: File::NULL)
    unless $CHILD_STATUS.exitstatus == 2 && OpenSSL::X509::Certificate.new(File.read("#{dir}/certificate.pem")).serial == 2
      abort "Renewal failed"
    end
    puts "Puppet: first run changed (2), second unchanged (0), renewal changed (2). File mtime unchanged on second run."
  end
ensure
  FileUtils.remove_entry(config_dir) if config_dir
  connection&.request("delete", "#{connection.path("#{prefix}/")}?recurse") if prefix&.start_with?("cci-idempotence/")
end
