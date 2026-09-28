# frozen_string_literal: true

require "rubygems/package"
require "zlib"
require "stringio"
require "open3"
require "tmpdir"

module CertificateDiagnostics
  module Sources
    # Never extract downloaded paths onto the filesystem. All decompression and
    # subprocess output is bounded; interrupted helpers are killed and reaped.
    class Archive
      def initialize(limit)
        @limit = limit
      end

      def gzip(bytes)
        Zlib::GzipReader.wrap(StringIO.new(bytes)) { |reader| bounded_read(reader) }
      end

      def tar(bytes)
        raise Error, "response_too_large" if bytes.bytesize > @limit

        output = {}
        Gem::Package::TarReader.new(StringIO.new(bytes)) do |archive|
          archive.each do |entry|
            next unless entry.file? && yield(entry.full_name)

            raise Error, "response_too_large" if entry.header.size > @limit

            output[entry.full_name] = entry.read
          end
        end
        output
      end

      def command(*args)
        result = nil
        Open3.popen3(*args) do |input, output, errors, waiter|
          input.close
          error_reader = Thread.new { bounded_read(errors) }
          begin
            result = bounded_read(output)
            raise Error, "source_verification_failed" unless waiter.value.success?

            error_reader.value
          ensure
            Process.kill("KILL", waiter.pid) if waiter.alive?
            error_reader.join
          end
        end
        result
      rescue Errno::ENOENT
        raise Error, "source_tool_unavailable"
      end

      def deb(bytes)
        raise Error, "unsupported_schema" unless bytes.start_with?("!<arch>\n")

        offset = 8
        while offset < bytes.bytesize
          header = bytes.byteslice(offset, 60)
          raise Error, "unsupported_schema" unless header&.bytesize == 60 && header.end_with?("`\n")

          size = Integer(header.byteslice(48, 10).strip, 10)
          raise Error, "response_too_large" unless size.between?(0, @limit)

          data = bytes.byteslice(offset + 60, size)
          raise Error, "unsupported_schema" unless data&.bytesize == size

          name = header.byteslice(0, 16).strip.delete_suffix("/")
          yield name, data
          offset += 60 + size + (size % 2)
        end
      end

      private

      def bounded_read(io)
        output = +"".b
        while (chunk = io.read(65_536))
          raise Error, "response_too_large" if output.bytesize + chunk.bytesize > @limit

          output << chunk
        end
        output
      end
    end
  end
end
