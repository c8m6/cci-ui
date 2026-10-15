# frozen_string_literal: true

require_relative "../lib/cci_configuration"

threads_count = CciConfiguration.current.dig("server", "threads")
threads threads_count, threads_count
port CciConfiguration.current.dig("server", "port")
environment ENV.fetch("RAILS_ENV", "development")
plugin :tmp_restart
quiet
