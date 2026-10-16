# frozen_string_literal: true

require "test_helper"
require "open3"

class OidcHttpJsonTest < ActiveSupport::TestCase
  test "production initialization configures JSON parsing for the actual OIDC clients" do
    data = YAML.safe_load_file(Rails.root.join("test/production.yml"))
    data["database"] = TEST_CONFIGURATION.fetch("database")
    data["consul"] = TEST_CONFIGURATION.fetch("consul")
    Dir.mktmpdir("cci-oidc-http-") do |dir|
      config_file = File.join(dir, "config.yml")
      File.write(config_file, YAML.dump(data))
      output, errors, status = Open3.capture3(
        { "RAILS_ENV" => "production", "CCI_CONFIG_FILE" => config_file },
        RbConfig.ruby, "-e", oidc_http_probe, chdir: Rails.root.to_s
      )
      assert status.success?, "OIDC HTTP probe failed:\n#{output}\n#{errors}"
      assert_includes output, "OIDC HTTP JSON compatibility verified"
      assert_not_includes output, "synthetic-access-token"
    end
  end

  private

  def oidc_http_probe
    <<~'RUBY'
      require_relative "config/environment"
      issuer = CciConfiguration.current.dig("authentication", "oidc", "issuer")
      metadata = {
        issuer: issuer, authorization_endpoint: "#{issuer}/authorize", token_endpoint: "#{issuer}/token",
        userinfo_endpoint: "#{issuer}/userinfo", jwks_uri: "#{issuer}/certs",
        response_types_supported: ["code"], subject_types_supported: ["public"], id_token_signing_alg_values_supported: ["RS256"]
      }
      headers = { "Content-Type" => "application/json" }
      stubs = Faraday::Adapter::Test::Stubs.new do |stub|
        stub.get("/realms/cci/.well-known/openid-configuration") { [200, headers, JSON.generate(metadata)] }
        stub.get("/realms/cci/certs") { [200, headers, '{"keys":[]}'] }
        stub.post("/realms/cci/token") do
          [200, headers, '{"access_token":"synthetic-access-token","token_type":"Bearer"}']
        end
        stub.get("/realms/cci/userinfo") { [200, headers, '{"sub":"synthetic-user","name":"Example User"}'] }
      end
      [SWD, OpenIDConnect, Rack::OAuth2].each do |library|
        connection = library.http_client
        connection.adapter :test, stubs
        library.define_singleton_method(:http_client) { |*_args| connection }
      end
      discovered = OpenIDConnect::Discovery::Provider::Config.discover!(issuer)
      abort "Discovery issuer mismatch" unless discovered.issuer == issuer
      abort "Unexpected signing keys" unless discovered.jwks.empty?
      client = OpenIDConnect::Client.new(identifier: "cci-ui", secret: "synthetic-only", host: URI(issuer).host,
        token_endpoint: discovered.token_endpoint, userinfo_endpoint: discovered.userinfo_endpoint)
      client.authorization_code = "synthetic-code"
      token = client.access_token!
      abort "Token exchange failed" unless token.access_token == "synthetic-access-token"
      abort "User information failed" unless token.userinfo!.sub == "synthetic-user"
      stubs.verify_stubbed_calls
      puts "OIDC HTTP JSON compatibility verified"
    RUBY
  end
end
