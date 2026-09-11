class LegacyStore
  def self.root = Pathname.new(ENV.fetch("LEGACY_PATH", Rails.root.join("data").to_s)).realpath
  def self.area = AreaConfiguration.legacy_area
  def self.safe_path(relative)
    path = root.join(relative).realpath
    raise Certificates::Error, "Datei liegt außerhalb des Altbestands." unless path.to_s.start_with?(root.to_s + File::SEPARATOR)
    path
  rescue Errno::ENOENT
    raise Certificates::Error, "Datei ist nicht mehr vorhanden."
  end
  def self.read(path)
    raise Certificates::Error, "Datei ist größer als 20 MB." if path.size > Certificates::Codec::MAX_BYTES
    path.binread
  rescue SystemCallError
    raise Certificates::Error, "Datei ist für die Anwendung nicht lesbar."
  end
  def self.certificates(relative)
    data = read(safe_path(relative))
    data.scan(/-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----/m).map { |pem| OpenSSL::X509::Certificate.new(pem) }
  rescue OpenSSL::OpenSSLError
    raise Certificates::Error, "Zertifikat im Dateibestand ist ungültig."
  end
  def self.key(relative, cert, password: "")
    pem = read(safe_path(relative))
    sibling = relative.sub(/\.pem\z/, ".key")
    begin
      pem += read(safe_path(sibling)) if sibling != relative && root.join(sibling).exist?
    rescue Certificates::Error
      raise
    end
    keys = pem.scan(/-----BEGIN (?:RSA |EC |ENCRYPTED )?PRIVATE KEY-----.*?-----END (?:RSA |EC |ENCRYPTED )?PRIVATE KEY-----/m)
    keys.each do |candidate|
      key = OpenSSL::PKey.read(candidate, password)
      return key if cert.check_private_key(key)
    end
    raise Certificates::Error, "Kein passender privater Schlüssel vorhanden."
  rescue OpenSSL::OpenSSLError
    raise Certificates::Error, "Privater Schlüssel ist geschützt oder ungültig. Quellpasswort prüfen."
  end
end
