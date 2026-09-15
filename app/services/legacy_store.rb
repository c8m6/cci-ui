class LegacyStore
  def self.areas = AreaConfiguration.legacy_paths.keys
  def self.area = AreaConfiguration.legacy_area
  def self.root(area: self.area)
    configured = AreaConfiguration.legacy_paths[area]
    raise Certificates::Error, "Für diesen Bereich ist kein Dateibestand konfiguriert. Index aktualisieren." unless configured
    Pathname.new(configured).realpath
  rescue SystemCallError
    raise Certificates::Error, "Der Dateibestand ist nicht erreichbar. Bitte Einbindung und Zugriffsrechte prüfen."
  end

  def self.safe_path(relative, area: self.area)
    base = root(area: area)
    path = base.join(relative).realpath
    raise Certificates::Error, "Datei liegt außerhalb des Altbestands." unless path.to_s.start_with?(base.to_s + File::SEPARATOR)
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
  def self.certificates(relative, area: self.area)
    data = read(safe_path(relative, area: area))
    blocks = data.scan(/-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----/m)
    if blocks.size != data.scan("-----BEGIN CERTIFICATE-----").size
      raise Certificates::Error, "Zertifikat im Dateibestand ist unvollständig."
    end
    blocks.map { |pem| OpenSSL::X509::Certificate.new(pem) }
  rescue OpenSSL::OpenSSLError
    raise Certificates::Error, "Zertifikat im Dateibestand ist ungültig."
  end
  # Read the actual inventory; an incomplete scan must never authorize deletion
  # or an import. Dir.children reports inaccessible directories instead of
  # silently omitting their contents as a recursive glob can do.
  def self.inventory(area: self.area)
    base = root(area: area)
    pending = [base]
    entries = []
    until pending.empty?
      directory = pending.pop
      directory.children.sort.each do |path|
        stat = path.lstat
        if stat.directory?
          pending << path
        elsif stat.symlink? && path.directory?
          raise Certificates::Error, "Verknüpfte Verzeichnisse im Dateibestand können nicht vollständig geprüft werden."
        elsif path.extname.downcase == ".pem"
          relative = path.relative_path_from(base).to_s
          entries << { relative: relative, certificates: certificates(relative, area: area) }
        end
      end
    end
    entries
  rescue SystemCallError
    raise Certificates::Error, "Der Dateibestand ist nicht vollständig lesbar. Bitte Einbindung und Zugriffsrechte prüfen."
  end

  def self.reject_duplicates!(fingerprints)
    existing = areas.flat_map do |area|
      inventory(area: area).flat_map { |entry| entry.fetch(:certificates).map { |cert| Certificates::Codec.fingerprint(cert) } }
    end.to_set
    if fingerprints.any? { |fingerprint| existing.include?(fingerprint) }
      raise Certificates::Error, "Upload abgelehnt: Mindestens ein Zertifikat ist bereits im Dateibestand vorhanden."
    end
  end

  def self.key(relative, cert, password: "", area: self.area)
    pem = read(safe_path(relative, area: area))
    sibling = relative.sub(/\.pem\z/i, ".key")
    begin
      pem += read(safe_path(sibling, area: area)) if sibling != relative && root(area: area).join(sibling).exist?
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
