# frozen_string_literal: true

# Shares a bounded dependency check result across requests in one web process.
class HealthCheckCache
  TTL = 10
  REFRESH_AFTER = 5

  def initialize(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
    @clock = clock
    @mutex = Mutex.new
    @checked_at = nil
    @updating = false
  end

  def fetch
    @mutex.synchronize do
      now = @clock.call
      return @result if @checked_at && now - @checked_at < REFRESH_AFTER
      return valid_result(now) if @updating

      @updating = true
    end

    begin
      result = yield
      @mutex.synchronize do
        @result = result
        @checked_at = @clock.call
      end
      result
    ensure
      @mutex.synchronize { @updating = false }
    end
  end

  private

  def valid_result(now)
    @result if @checked_at && now - @checked_at < TTL
  end
end
