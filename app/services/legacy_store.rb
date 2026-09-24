# frozen_string_literal: true

# Reads mounted inventories safely; confirmed retirement is handled by LegacyDeletion.
class LegacyStore
  def self.areas = AreaConfiguration.legacy_paths.keys
  def self.area = AreaConfiguration.legacy_area

  def self.root(area: self.area)
    configured = AreaConfiguration.legacy_paths[area]
    raise Certificates::Error, I18n.t("errors.app.no_inventory") unless configured

    Pathname.new(configured).realpath
  rescue SystemCallError
    raise Certificates::Error, I18n.t("errors.app.inventory_unavailable")
  end

  def self.safe_path(relative, area: self.area)
    base = root(area: area)
    path = base.join(relative).realpath
    raise Certificates::Error, I18n.t("errors.app.file_outside") unless path.to_s.start_with?(base.to_s + File::SEPARATOR)

    path
  rescue Errno::ENOENT
    raise Certificates::Error, I18n.t("errors.app.file_missing")
  end

  def self.read(path)
    raise Certificates::Error, I18n.t("errors.app.file_size") if path.size > Certificates::Codec::MAX_BYTES

    path.binread
  rescue SystemCallError
    raise Certificates::Error, I18n.t("errors.app.file_unreadable")
  end

  def self.certificates(relative, area: self.area)
    data = read(safe_path(relative, area: area))
    blocks = data.scan(/-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----/m)
    if blocks.size != data.scan("-----BEGIN CERTIFICATE-----").size
      raise Certificates::Error, I18n.t("errors.app.inventory_incomplete_cert")
    end

    blocks.map { |pem| OpenSSL::X509::Certificate.new(pem) }
  rescue OpenSSL::OpenSSLError
    raise Certificates::Error, I18n.t("errors.app.inventory_invalid_cert")
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
          raise Certificates::Error, I18n.t("errors.app.inventory_symlinks")
        elsif path.extname.downcase == ".pem"
          relative = path.relative_path_from(base).to_s
          entries << { relative: relative, certificates: certificates(relative, area: area) }
        end
      end
    end
    entries
  rescue SystemCallError
    raise Certificates::Error, I18n.t("errors.app.inventory_unreadable")
  end

  def self.reject_duplicates!(fingerprints)
    existing = areas.flat_map do |area|
      inventory(area: area).flat_map { |entry| entry.fetch(:certificates).map { |cert| Certificates::Codec.fingerprint(cert) } }
    end.to_set
    return unless fingerprints.any? { |fingerprint| existing.include?(fingerprint) }

    raise Certificates::Error, I18n.t("errors.app.inventory_duplicate")
  end

  def self.key(relative, cert, password: "", area: self.area)
    pem = read(safe_path(relative, area: area))
    sibling = relative.sub(/\.pem\z/i, ".key")
    pem += read(safe_path(sibling, area: area)) if sibling != relative && root(area: area).join(sibling).exist?
    keys = pem.scan(/-----BEGIN (?:RSA |EC |ENCRYPTED )?PRIVATE KEY-----.*?-----END (?:RSA |EC |ENCRYPTED )?PRIVATE KEY-----/m)
    keys.each do |candidate|
      key = OpenSSL::PKey.read(candidate, password)
      return key if cert.check_private_key(key)
    end
    raise Certificates::Error, I18n.t("errors.app.no_matching_key")
  rescue OpenSSL::OpenSSLError
    raise Certificates::Error, I18n.t("errors.app.protected_key")
  end
end
