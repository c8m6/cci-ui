require "cci_client"
require "area_secrets"

Puppet::Functions.create_function(:"cci::lookup") do
  dispatch :lookup do
    param "Pattern[/^[a-z][a-z0-9_]{0,47}$/]", :area
    param "String[1]", :name
    optional_param "Enum['certificate', 'chain', 'private_key', 'metadata']", :field
    optional_param "Optional[String]", :version
  end
  def lookup(area, name, field = "certificate", version = nil)
    compiler = closure_scope.compiler
    clients = compiler.instance_variable_get(:@cci_clients) || compiler.instance_variable_set(:@cci_clients, {})
    client = clients[area] ||= CciClient.new(
      url: ENV.fetch("CCI_CONSUL_URL"), token: ENV.fetch("CCI_#{area.upcase}_CONSUL_TOKEN", ""),
      prefix: ENV.fetch("CCI_CONSUL_PREFIX", "cci/v1"), keys: { area => AreaSecrets.fetch(area) })
    value = client.fetch(area: area, lookup: name, field: field, version: version)
    field == "private_key" ? Puppet::Pops::Types::PSensitiveType::Sensitive.new(value) : value
  rescue CciClient::Error, KeyError, ArgumentError
    raise Puppet::Error, "CCI-UI: Zertifikat konnte nicht aus dem berechtigten Bereich gelesen werden."
  end
end
