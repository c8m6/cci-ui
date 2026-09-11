ENV["CCI_AREAS_FILE"] = File.expand_path("fixtures/areas.yml", __dir__)
require 'openssl'
require 'json'
require 'base64'
require 'tmpdir'
require 'securerandom'
require 'etc'
require_relative '../lib/consul_connection'
require_relative '../lib/certificates/error'
require_relative '../lib/certificates/vault'
begin
url = ENV.fetch('CCI_CONSUL_URL')
prefix = "cci-idempotence/#{SecureRandom.hex(8)}"
connection = ConsulConnection.new(url: url)
ENV['ZONE_A_KEY'] = Base64.strict_encode64(SecureRandom.random_bytes(32))
ENV['CCI_CONSUL_PREFIX'] = prefix
certkey = OpenSSL::PKey::RSA.new(2048)
cert = OpenSSL::X509::Certificate.new
cert.version=2; cert.serial=1
cert.subject=cert.issuer=OpenSSL::X509::Name.parse('/CN=puppet.example.test')
cert.public_key=certkey.public_key
cert.not_before=Time.now-3600; cert.not_after=Time.now+86400
cert.sign(certkey, OpenSSL::Digest::SHA256.new)
id = Digest::SHA256.hexdigest(cert.to_der)
base="#{prefix}/areas/zone_a"
data={schema:'1',entry_id:'test',pem:cert.to_pem,chain:'[]',fingerprint:id,public_key_fingerprint:Digest::SHA256.hexdigest(certkey.public_to_der),has_key:'1'}
connection.transaction([
 ConsulConnection.set("#{base}/lookups/test",{entry_id:'test',active_version:id}),
 ConsulConnection.set("#{base}/versions/#{id}",data),
 ConsulConnection.set("#{base}/private-keys/#{id}",Certificates::Vault.encrypt(certkey.private_to_pem,area:'zone_a',id:id))
])
Dir.mktmpdir('cci-puppet-') do |dir|
 manifest=File.join(dir,'test.pp')
 File.write(manifest,"cci::certificate { 'test': area => 'zone_a', path => '#{dir}/certificate.pem', key_path => '#{dir}/key.pem', owner => '#{Etc.getpwuid.name}', group => '#{Etc.getgrgid(Process.gid).name}' }\n")
 command=['puppet','apply','--modulepath',File.expand_path('../integrations/puppet',__dir__),'--vardir',"#{dir}/var",'--publicdir',"#{dir}/public",'--ssldir',"#{dir}/ssl",'--statedir',"#{dir}/state",'--confdir',"#{dir}/conf",'--logdir',"#{dir}/log",'--rundir',"#{dir}/run",'--detailed-exitcodes',manifest]
 system(*command, out: File::NULL)
 first=$?.exitstatus
 before=File.mtime("#{dir}/certificate.pem")
 system(*command, out: File::NULL)
 second=$?.exitstatus
 after=File.mtime("#{dir}/certificate.pem")
 abort "Idempotence failed #{first}/#{second}" unless first==2 && second==0 && before==after
 cert.serial=2; cert.sign(certkey,OpenSSL::Digest::SHA256.new)
 newer=Digest::SHA256.hexdigest(cert.to_der)
 data[:pem]=cert.to_pem;data[:fingerprint]=newer
 connection.transaction([
  ConsulConnection.set("#{base}/lookups/test",{entry_id:'test',active_version:newer}),
  ConsulConnection.set("#{base}/versions/#{newer}",data),
  ConsulConnection.set("#{base}/private-keys/#{newer}",Certificates::Vault.encrypt(certkey.private_to_pem,area:'zone_a',id:newer))
 ])
 system(*command, out: File::NULL)
 abort 'Renewal failed' unless $?.exitstatus==2 && OpenSSL::X509::Certificate.new(File.read("#{dir}/certificate.pem")).serial==2
 puts 'Puppet: first run changed (2), second unchanged (0), renewal changed (2). File mtime unchanged on second run.'
end
ensure
 connection&.request('delete',connection.path(prefix + '/')+'?recurse') if prefix&.start_with?('cci-idempotence/')

end
