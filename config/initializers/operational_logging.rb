# frozen_string_literal: true

require Rails.root.join("lib/operational_log")

ActiveSupport::Notifications.subscribe("sql.active_record") do |event|
  OperationalLog.database_write(event.payload)
end
