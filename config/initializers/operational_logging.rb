# frozen_string_literal: true

# SQL output is intentionally disabled at every level. Business writes are
# represented by application and audit events instead.
Rails.application.config.after_initialize do
  ActiveRecord::Base.logger = nil
end
