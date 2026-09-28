# frozen_string_literal: true

module CertificateDiagnostics
  module Sources
    # Verify signed archive metadata and both checksum links before reading the
    # package. No package installation and no host/container root-store fallback.
    class Ubuntu
      SIGNER = "F6ECB3762474EDA9D21B7022871920D1991BC93C"
      BASE = "https://archive.ubuntu.com/ubuntu/"
      INDEX = "main/binary-amd64/Packages.gz"

      def initialize(download, target:, max_age:, archive:)
        @download = download
        @target = target
        @max_age = max_age
        @archive = archive
      end

      def call
        release = get("#{BASE}dists/#{@target}/InRelease")
        verify_release(release)
        index = get("#{BASE}dists/#{@target}/#{INDEX}")
        checksum = release[/^ ([a-f0-9]{64})\s+\d+ #{Regexp.escape(INDEX)}$/, 1]
        verify_digest(index, checksum)
        package = @archive.gzip(index).split("\n\n").find { |entry| entry.start_with?("Package: ca-certificates\n") }
        raise Error, "source_unavailable" unless package

        fields = package.lines.filter_map { |line| line.strip.split(": ", 2) if line.match?(/\A[A-Za-z0-9-]+: /) }.to_h
        path = fields.fetch("Filename")
        raise Error, "source_verification_failed" unless path.match?(%r{\Apool/main/c/ca-certificates/[a-zA-Z0-9_.~+-]+\.deb\z})

        bytes = get("#{BASE}#{path}")
        verify_digest(bytes, fields.fetch("SHA256"))
        roots, notice = certificates(bytes)
        { "roots" => roots, "release" => "Ubuntu 24.04 LTS #{@target}; ca-certificates #{fields.fetch("Version")}",
          "source" => "#{BASE}#{path}", "scope" => "ubuntu_baseline", "notice" => notice,
          "repository_date" => release[/^Date: (.+)$/, 1] }
      end

      private

      def get(url) = @download.get(url, max_age: @max_age)

      def verify_digest(bytes, expected)
        raise Error, "source_verification_failed" unless expected && Digest::SHA256.hexdigest(bytes) == expected
      end

      def verify_release(bytes)
        key = get("https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x#{SIGNER}")
        Dir.mktmpdir("cci-ubuntu-") do |dir|
          File.binwrite("#{dir}/key.asc", key)
          File.binwrite("#{dir}/InRelease", bytes)
          @archive.command("gpg", "--batch", "--homedir", dir, "--dearmor", "--output", "#{dir}/key.gpg", "#{dir}/key.asc")
          status = @archive.command("gpgv", "--homedir", dir, "--status-fd", "1", "--keyring", "#{dir}/key.gpg", "#{dir}/InRelease")
          raise Error, "source_verification_failed" unless status.lines.any? { |line| line.start_with?("[GNUPG:] VALIDSIG #{SIGNER} ") }
        end
        date = Time.parse(bytes[/^Date: (.+)$/, 1])
        expiry = bytes[/^Valid-Until: (.+)$/, 1]
        return unless date > Time.current + 300 || date < Time.current - 7.days || (expiry && Time.parse(expiry) <= Time.current)

        raise Error,
          "source_expired"
      end

      def certificates(bytes)
        files = {}
        @archive.deb(bytes) do |name, data|
          next unless %w[data.tar.xz data.tar.zst].include?(name)

          Dir.mktmpdir("cci-package-") do |dir|
            path = "#{dir}/#{name}"
            File.binwrite(path, data)
            program = if name.end_with?(".zst")
                        ["zstd", "--decompress", "--stdout", "--memory=64MB"]
                      else
                        ["xz", "--decompress", "--stdout", "--memlimit-decompress=64MiB"]
                      end
            files = @archive.tar(@archive.command(*program, path)) do |entry|
              entry.start_with?("./usr/share/ca-certificates/mozilla/") || entry == "./usr/share/doc/ca-certificates/copyright"
            end
          end
        end
        notice = files.delete("./usr/share/doc/ca-certificates/copyright")
        raise Error, "source_verification_failed" unless notice && files.any?

        roots = files.values.to_h do |pem|
          cert = OpenSSL::X509::Certificate.new(pem)
          [Certificates::Codec.fingerprint(cert), { "pem" => cert.to_pem }]
        end
        [roots, notice]
      end
    end
  end
end
