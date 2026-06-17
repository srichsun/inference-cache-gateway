require "test_helper"

class LockAndFetchRateTest < ActiveSupport::TestCase
  LOCK_KEY      = "pricing:bulk_fetch".freeze
  RATE_CACHE_KEY = "pricing:Summer:FloatingPointResort:SingletonRoom".freeze

  setup do
    Rails.cache.clear
  end

  # --- Happy path (leader) ---

  test "leader executes block and returns result when lock is available" do
    result = LockAndFetchRate.call(LOCK_KEY, RATE_CACHE_KEY) { 55_700 }

    assert_equal 55_700, result
  end

  # --- Fail path (follower timeout) ---

  test "follower raises TimeoutError when leader crashed and cache is never populated" do
    # Scenario: leader crashed (kill -9), lock is stuck, cache was never written.
    # This request sees the lock → becomes a follower → polls for cache →
    # cache never appears → gives up after FOLLOWER_TIMEOUT → TimeoutError.
    Rails.cache.write("lock_and_fetch_rate:#{LOCK_KEY}", true, expires_in: LockAndFetchRate::UPSTREAM_LOCK_AUTO_EXPIRE)

    # Shorten timeout from 6s to 0.2s so the test runs fast.
    original = LockAndFetchRate::FOLLOWER_TIMEOUT
    LockAndFetchRate.send(:remove_const, :FOLLOWER_TIMEOUT)
    LockAndFetchRate.const_set(:FOLLOWER_TIMEOUT, 0.2.seconds)

    assert_raises(LockAndFetchRate::TimeoutError) do
      # This is a follower — lock already exists, so this block never runs.
      # If the block runs by mistake, "should not execute" blows up the test
      # so we know something is wrong.
      LockAndFetchRate.call(LOCK_KEY, RATE_CACHE_KEY) { raise "should not execute" }
    end
  ensure
    LockAndFetchRate.send(:remove_const, :FOLLOWER_TIMEOUT)
    LockAndFetchRate.const_set(:FOLLOWER_TIMEOUT, original)
  end

  # --- Edge / Boundary ---

  test "lock is released when leader finishes successfully" do
    LockAndFetchRate.call(LOCK_KEY, RATE_CACHE_KEY) { 55_700 }

    assert_nil Rails.cache.read("lock_and_fetch_rate:#{LOCK_KEY}")
  end

  test "lock is released when block raises an error" do
    assert_raises(RuntimeError) do
      LockAndFetchRate.call(LOCK_KEY, RATE_CACHE_KEY) { raise "boom" }
    end
    assert_nil Rails.cache.read("lock_and_fetch_rate:#{LOCK_KEY}")
  end

  # --- Isolation (follower reads cache, not block) ---

  test "follower reads cached value instead of executing block when leader already populated cache" do
    # Simulate a leader already in progress: lock held, cache populated
    Rails.cache.write("lock_and_fetch_rate:#{LOCK_KEY}", true, expires_in: LockAndFetchRate::UPSTREAM_LOCK_AUTO_EXPIRE)
    Rails.cache.write(RATE_CACHE_KEY, 55_700, expires_in: 5.minutes)

    result = LockAndFetchRate.call(LOCK_KEY, RATE_CACHE_KEY) { raise "block should not run for follower" }

    assert_equal 55_700, result
  end

  test "concurrent requests collapse into a single block execution when multiple threads hit cache miss" do
    upstream_call_count = 0
    mutex = Mutex.new

    threads = 5.times.map do
      Thread.new do
        LockAndFetchRate.call(LOCK_KEY, RATE_CACHE_KEY) do
          mutex.synchronize { upstream_call_count += 1 }
          sleep(0.1) # simulate upstream latency
          Rails.cache.write(RATE_CACHE_KEY, 55_700, expires_in: 5.minutes)
          55_700
        end
      end
    end

    results = threads.map(&:value)

    assert_equal 1, upstream_call_count, "Expected exactly 1 upstream call, got #{upstream_call_count}"
    assert results.all? { |r| r == 55_700 }, "All threads should receive the same rate"
  end
end
