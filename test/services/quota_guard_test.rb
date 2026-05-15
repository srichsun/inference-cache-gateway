require "test_helper"

class QuotaGuardTest < ActiveSupport::TestCase
  setup do
    # Clear the quota counter before each test
    redis = Redis.new(url: ENV.fetch("REDIS_URL_TEST", "redis://localhost:6379/1"))
    redis.del("quota:#{Time.zone.today}")
  end

  teardown do
    Timecop.return
  end

  # --- Happy path ---

  test "consume_quota! returns true when usage is under daily limit" do
    assert QuotaGuard.consume_quota!
  end

  # --- Boundary ---

  test "the 1000th call still passes and the 1001st raises when reaching daily limit" do
    # First 999 calls
    (QuotaGuard::DAILY_LIMIT - 1).times { QuotaGuard.consume_quota! }

    # Call #1000 — exactly at the limit, should still pass
    assert QuotaGuard.consume_quota!

    # Call #1001 — over budget, must raise
    assert_raises(QuotaGuard::ExhaustedError) do
      QuotaGuard.consume_quota!
    end
  end

  # --- Refund ---

  test "refund_quota! decrements the counter by one" do
    QuotaGuard.consume_quota!
    QuotaGuard.consume_quota!
    QuotaGuard.refund_quota!

    # Counter should be back to 1 — one more call should still pass
    assert QuotaGuard.consume_quota!
  end

  test "quota is restored after a 401 so subsequent valid calls can proceed" do
    # Exhaust all but the last unit
    (QuotaGuard::DAILY_LIMIT - 1).times { QuotaGuard.consume_quota! }

    # Simulate a 401: consume then refund
    QuotaGuard.consume_quota!
    QuotaGuard.refund_quota!

    # The refunded unit means one more call should still pass
    assert QuotaGuard.consume_quota!
  end

  test "refund_quota! does not push the counter below zero" do
    # No prior INCR — counter doesn't exist yet
    QuotaGuard.refund_quota!
    QuotaGuard.refund_quota!
    QuotaGuard.refund_quota!

    # Now do 1000 valid calls — they should all pass.
    # If refund had pushed the counter to -3, the 1003rd call would
    # silently slip through, breaking the cap.
    QuotaGuard::DAILY_LIMIT.times { assert QuotaGuard.consume_quota! }

    # 1001st call must still raise
    assert_raises(QuotaGuard::ExhaustedError) do
      QuotaGuard.consume_quota!
    end
  end

  # --- Daily reset (Timecop) ---

  test "counter resets when date changes to a new day" do
    # Use up entire quota today
    QuotaGuard::DAILY_LIMIT.times { QuotaGuard.consume_quota! }

    # Jump to tomorrow — new day, new budget
    Timecop.travel(Date.tomorrow) do
      assert QuotaGuard.consume_quota!
    end
  end
end
