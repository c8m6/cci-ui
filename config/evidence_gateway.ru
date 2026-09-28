# frozen_string_literal: true

require_relative "../lib/evidence_gateway"

run EvidenceGateway::App.new(schedule: true)
