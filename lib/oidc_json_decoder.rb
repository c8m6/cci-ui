# frozen_string_literal: true

require "json"

# Adapts Faraday parser options to the keyword arguments required by JSON 3.
module OidcJsonDecoder
  def self.parse(body, options = {})
    JSON.parse(body, **options)
  end
end
