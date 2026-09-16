require "net/http"
require "uri"
require "json"
require "openssl"

class PuppetdbConnection
  class Error < StandardError; end

  def initialize(environment: ENV)
    @environment = environment
    @uri = URI(environment.fetch("PUPPETDB_URL", ""))
    unless %w[http https].include?(@uri.scheme) && @uri.host && !@uri.userinfo && !@uri.query && !@uri.fragment
      raise Error, "PUPPETDB_URL muss eine HTTP(S)-Basis-URL ohne Zugangsdaten, Query oder Fragment sein."
    end
    @uri.path = @uri.path.sub(%r{/+\z}, "") + "/pdb/query/v4"
    @uri.query = "include_total=true"
    @timeout = positive_integer("PUPPETDB_TIMEOUT", 30)
    @max_bytes = positive_integer("PUPPETDB_MAX_RESPONSE_BYTES", 50 * 1024 * 1024)
    @token = environment.fetch("PUPPETDB_TOKEN", "")
    @cert_file = environment.fetch("PUPPETDB_CLIENT_CERT_FILE", "")
    @key_file = environment.fetch("PUPPETDB_CLIENT_KEY_FILE", "")
    if @cert_file.empty? != @key_file.empty?
      raise Error, "PuppetDB benötigt Client-Zertifikat und privaten Schlüssel gemeinsam."
    end
    if @uri.scheme != "https" && (!@token.empty? || !@cert_file.empty?)
      raise Error, "PuppetDB-Zugangsdaten benötigen HTTPS."
    end
  rescue URI::InvalidURIError
    raise Error, "PUPPETDB_URL ist ungültig."
  end

  # Fetch the complete result in one request so changing factsets cannot move
  # hosts between offset pages. Never publish a truncated or partial response.
  def inventory(query)
    http = Net::HTTP.new(@uri.host, @uri.port, nil)
    http.use_ssl = @uri.scheme == "https"
    http.open_timeout = [@timeout, 5].min
    http.read_timeout = @timeout
    http.write_timeout = @timeout
    http.max_retries = 0
    if http.use_ssl?
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.verify_hostname = true
      ca_file = @environment.fetch("PUPPETDB_CA_FILE", "")
      http.ca_file = ca_file unless ca_file.empty?
      unless @cert_file.empty?
        http.cert = OpenSSL::X509::Certificate.new(File.binread(@cert_file))
        http.key = OpenSSL::PKey.read(File.binread(@key_file), "")
      end
    end
    request = Net::HTTP::Post.new(@uri)
    request["Content-Type"] = "application/json"
    request["Accept"] = "application/json"
    request["X-Authentication"] = @token unless @token.empty?
    request.body = JSON.generate(query: query)
    body = +""
    total = nil
    http.request(request) do |response|
      unless response.code == "200"
        raise Error, "PuppetDB-Anfrage fehlgeschlagen (HTTP #{response.code})."
      end
      total = response["X-Records"]
      response.read_body do |chunk|
        raise Error, "PuppetDB-Antwort überschreitet PUPPETDB_MAX_RESPONSE_BYTES." if body.bytesize + chunk.bytesize > @max_bytes
        body << chunk
      end
    end
    rows = JSON.parse(body)
    raise Error, "PuppetDB muss ein JSON-Array mit Host-Inventaren liefern." unless rows.is_a?(Array)
    if total && (!total.match?(/\A\d+\z/) || total.to_i != rows.size)
      raise Error, "PuppetDB hat ein unvollständiges Ergebnis geliefert. Hostzuordnungen bleiben erhalten."
    end
    rows
  rescue IOError, SystemCallError, Timeout::Error, SocketError, OpenSSL::OpenSSLError, JSON::ParserError, Net::HTTPBadResponse, EOFError
    raise Error, "PuppetDB ist nicht erreichbar oder lieferte eine ungültige Antwort. TLS und Verbindung prüfen."
  end

  private

  def positive_integer(name, default)
    value = Integer(@environment.fetch(name, default).to_s, 10)
    raise ArgumentError unless value.positive?
    value
  rescue ArgumentError, TypeError
    raise Error, "#{name} muss eine positive ganze Zahl sein."
  end
end
