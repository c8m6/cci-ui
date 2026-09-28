# frozen_string_literal: true

require "strscan"

module CertificateDiagnostics
  module Sources
    # Strict subset of protobuf text format used by the pinned root-store source.
    # Unknown fields are retained for policy validation, never silently dropped.
    class TextProto
      def self.parse(text)
        new(text).message
      end

      def initialize(text)
        @scanner = StringScanner.new(text)
      end

      def message(depth = 0)
        raise Error, "unsupported_schema" if depth > 12

        fields = {}
        loop do
          skip
          break if @scanner.eos? || @scanner.peek(1) == "}"

          name = @scanner.scan(/[a-zA-Z_][a-zA-Z_0-9]*/)
          raise Error, "unsupported_schema" unless name

          skip
          @scanner.scan(":")
          skip
          value = @scanner.scan("{") ? nested(depth) : scalar
          (fields[name] ||= []) << value
        end
        raise Error, "unsupported_schema" if depth.zero? && !@scanner.eos?

        fields
      end

      private

      def skip
        @scanner.skip(%r{(?:\s+|#[^\n]*|//[^\n]*)*})
      end

      def nested(depth)
        result = message(depth + 1)
        raise Error, "unsupported_schema" unless @scanner.scan("}")

        result
      end

      def scalar
        token = @scanner.scan(/"(?:[^"\\]|\\.)*"/)
        if token
          return JSON.parse(token.gsub(/\\x([0-9a-fA-F]{2})/) { "\\u00#{Regexp.last_match(1)}" }
            .gsub(/\\([0-7]{1,3})/) { format("\\u%04x", Regexp.last_match(1).to_i(8)) })
        end

        token = @scanner.scan(/-?\d+|true\b|false\b/)
        raise Error, "unsupported_schema" unless token

        JSON.parse(token)
      end
    end
  end
end
