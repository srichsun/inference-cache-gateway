require "test_helper"

class RateCacheTest < ActiveSupport::TestCase
  PARAMS        = { period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom" }.freeze
  COMBO_KEY     = "Summer:FloatingPointResort:SingletonRoom".freeze
  COMBO_KEY_ALT = "Summer:FloatingPointResort:BooleanTwin".freeze

  setup do
    # Start each test with a clean cache to avoid cross-test pollution.
    Rails.cache.clear
  end

  teardown do
    Timecop.return
  end

  # --- Happy path ---

  test "read returns the rate that was written" do
    RateCache.write_all(COMBO_KEY => 55_700)

    assert_equal 55_700, RateCache.read(**PARAMS)
  end

  # --- Fail path ---

  test "read returns nil when no entry has been written" do
    assert_nil RateCache.read(**PARAMS)
  end

  # --- Edge / Boundary ---

  test "cache entry is still valid at 4 minutes 59 seconds" do
    Timecop.freeze do
      RateCache.write_all(COMBO_KEY => 55_700)

      Timecop.travel(4.minutes + 59.seconds)

      assert_equal 55_700, RateCache.read(**PARAMS)
    end
  end

  test "cache entry expires after 5 minutes" do
    Timecop.freeze do
      RateCache.write_all(COMBO_KEY => 55_700)

      Timecop.travel(5.minutes + 1.second)

      assert_nil RateCache.read(**PARAMS)
    end
  end

  # --- Isolation ---

  test "different room produces a separate cache entry when multiple combos are cached" do
    RateCache.write_all(COMBO_KEY => 55_700, COMBO_KEY_ALT => 12_300)

    assert_equal 55_700, RateCache.read(**PARAMS)
    assert_equal 12_300, RateCache.read(**PARAMS, room: "BooleanTwin")
  end

  test "cache_key includes all three dimensions" do
    key = RateCache.cache_key(**PARAMS)

    assert_equal "pricing:Summer:FloatingPointResort:SingletonRoom", key
  end
end
