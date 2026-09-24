# frozen_string_literal: true

# Readiness checks only the shared database, without modifying application data.
class ApplicationReadiness
  class Unavailable < StandardError; end

  def self.check
    ActiveRecord::Base.connection_pool.with_connection do |connection|
      connection.uncached do
        connection.transaction(requires_new: true) do
          connection.execute("SET LOCAL statement_timeout = '2s'")
          connection.execute("SET LOCAL lock_timeout = '1s'")
          readonly = connection.select_value("SELECT pg_is_in_recovery() OR current_setting('transaction_read_only')::boolean")
          raise Unavailable, "PostgreSQL is read-only" if readonly
          raise Unavailable, "Database migrations are pending" if connection.pool.migration_context.needs_migration?

          raise ActiveRecord::Rollback
        end
      end
    end
    {}
  rescue StandardError => e
    { "postgresql" => e }
  end
end
