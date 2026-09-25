# frozen_string_literal: true

# Abstract base for the PostgreSQL catalogue, draft and audit models.
class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  after_create_commit { log_committed_write("create") }
  after_update_commit { log_committed_write("update") }
  after_destroy_commit { log_committed_write("destroy") }

  private

  def log_committed_write(operation)
    OperationalLog.emit("record.committed", table: self.class.table_name, id: id, operation: operation)
  end
end
