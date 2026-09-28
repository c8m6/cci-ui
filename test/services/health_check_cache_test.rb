# frozen_string_literal: true

require "test_helper"

class HealthCheckCacheTest < ActiveSupport::TestCase
  test "parallel requests share one check and receive 503 until the first result exists" do
    now = 0.0
    cache = HealthCheckCache.new(clock: -> { now })
    started = Queue.new
    release = Queue.new
    worker = Thread.new do
      cache.fetch do
        started << true
        release.pop
        {}
      end
    end
    started.pop

    assert_nil(cache.fetch { flunk "A second check started" })
    release << true
    assert_equal({}, worker.value)
    assert_equal({}, cache.fetch { flunk "A cached check repeated" })
  ensure
    release << true if worker&.alive?
    worker&.join
  end

  test "parallel refresh serves only a still valid result and expires stale success" do
    now = 0.0
    cache = HealthCheckCache.new(clock: -> { now })
    assert_equal({}, cache.fetch { {} })

    now = 5.0
    started = Queue.new
    release = Queue.new
    worker = Thread.new do
      cache.fetch do
        started << true
        release.pop
        { "consul" => IOError.new("offline") }
      end
    end
    started.pop
    assert_equal({}, cache.fetch { flunk "A second refresh started" })

    now = 10.0
    assert_nil(cache.fetch { flunk "An expired success was refreshed in parallel" })
    release << true
    assert worker.value.key?("consul")
    assert cache.fetch { flunk "A failed check repeated" }.key?("consul")
  ensure
    release << true if worker&.alive?
    worker&.join
  end
end
