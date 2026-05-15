require "test_helper"

class RateApiClientTest < ActiveSupport::TestCase
  RATE_API_URL = ENV.fetch("RATE_API_URL", "http://rate-api:8080")

  def stub_upstream(status:, body:)
    stub_request(:post, "#{RATE_API_URL}/pricing")
      .to_return(status: status, body: body.to_json, headers: { "Content-Type" => "application/json" })
  end

  # Build the standard 36-rate response, optionally with one tweaked entry.
  # tweak: a lambda that modifies a copy of one entry (the Summer/FloatingPoint/Singleton one).
  def bulk_rates(tweak: nil)
    PricingConstants::ALL_COMBINATIONS.map do |combo|
      h = combo.transform_keys(&:to_s).merge("rate" => 10_000)
      if tweak && h["period"] == "Summer" && h["hotel"] == "FloatingPointResort" && h["room"] == "SingletonRoom"
        tweak.call(h)
      else
        h
      end
    end
  end

  # --- Happy path ---

  test "get_all_rates returns a hash of all 36 rate combinations" do
    stub_upstream(status: 200, body: { "rates" => bulk_rates })

    result = RateApiClient.get_all_rates

    assert_kind_of Hash, result
    assert_equal 36, result.size
    assert_equal 10_000, result["Summer:FloatingPointResort:SingletonRoom"]
  end

  # Upstream returns all rates as String ~7% of the time (Test 2 #4 in UPSTREAM_BEHAVIOR.md)
  test "get_all_rates coerces String integer rates to Integer" do
    rates = PricingConstants::ALL_COMBINATIONS.map do |combo|
      combo.transform_keys(&:to_s).merge("rate" => "10000")
    end
    stub_upstream(status: 200, body: { "rates" => rates })

    result = RateApiClient.get_all_rates

    assert_equal 36, result.size
    assert_kind_of Integer, result.values.first
    assert_equal 10_000, result.values.first
  end

  test "get_all_rates accepts Float rates (no silent truncation)" do
    rates = PricingConstants::ALL_COMBINATIONS.map do |combo|
      combo.transform_keys(&:to_s).merge("rate" => 100.50)
    end
    stub_upstream(status: 200, body: { "rates" => rates })

    result = RateApiClient.get_all_rates

    assert_equal 36, result.size
    assert_in_delta 100.50, result.values.first, 0.0001
  end

  test "get_all_rates accepts decimal String rates" do
    rates = PricingConstants::ALL_COMBINATIONS.map do |combo|
      combo.transform_keys(&:to_s).merge("rate" => "100.50")
    end
    stub_upstream(status: 200, body: { "rates" => rates })

    result = RateApiClient.get_all_rates

    assert_equal 36, result.size
    assert_in_delta 100.50, result.values.first, 0.0001
  end

  # --- Tolerant: skip invalid entries, keep valid ones ---

  test "get_all_rates skips entry with unknown hotel value (keeps 35 valid)" do
    rates = bulk_rates(tweak: ->(h) { h.merge("hotel" => "MarsResort") })
    stub_upstream(status: 200, body: { "rates" => rates })

    result = RateApiClient.get_all_rates

    assert_equal 35, result.size, "should drop the 1 entry with unknown hotel"
    assert_nil result["Summer:MarsResort:SingletonRoom"]
  end

  test "get_all_rates skips entry with unknown period value" do
    rates = bulk_rates(tweak: ->(h) { h.merge("period" => "Monsoon") })
    stub_upstream(status: 200, body: { "rates" => rates })

    result = RateApiClient.get_all_rates

    assert_equal 35, result.size
  end

  test "get_all_rates skips entry with unknown room value" do
    rates = bulk_rates(tweak: ->(h) { h.merge("room" => "PenthouseSuite") })
    stub_upstream(status: 200, body: { "rates" => rates })

    result = RateApiClient.get_all_rates

    assert_equal 35, result.size
  end

  test "get_all_rates skips entry with missing period field" do
    rates = bulk_rates(tweak: ->(h) { h.except("period") })
    stub_upstream(status: 200, body: { "rates" => rates })

    result = RateApiClient.get_all_rates

    assert_equal 35, result.size
  end

  test "get_all_rates skips entry with zero rate" do
    rates = bulk_rates(tweak: ->(h) { h.merge("rate" => 0) })
    stub_upstream(status: 200, body: { "rates" => rates })

    result = RateApiClient.get_all_rates

    assert_equal 35, result.size
  end

  test "get_all_rates skips entry with negative rate" do
    rates = bulk_rates(tweak: ->(h) { h.merge("rate" => -100) })
    stub_upstream(status: 200, body: { "rates" => rates })

    result = RateApiClient.get_all_rates

    assert_equal 35, result.size
  end

  test "get_all_rates skips entry with non-numeric rate" do
    rates = bulk_rates(tweak: ->(h) { h.merge("rate" => "not_a_number") })
    stub_upstream(status: 200, body: { "rates" => rates })

    result = RateApiClient.get_all_rates

    assert_equal 35, result.size
  end

  # --- Loud failure: when whole response is unusable ---

  test "get_all_rates raises UpstreamError when rates array is empty" do
    stub_upstream(status: 200, body: { "rates" => [] })

    assert_raises(RateApiClient::UpstreamError) { RateApiClient.get_all_rates }
  end

  test "get_all_rates raises UpstreamError when response has error body" do
    stub_upstream(status: 200, body: { "message" => "Failed to process rates", "status" => "error" })

    assert_raises(RateApiClient::UpstreamError) { RateApiClient.get_all_rates }
  end

  test "get_all_rates raises UpstreamError when rates is not an array" do
    stub_upstream(status: 200, body: { "rates" => "not_an_array" })

    assert_raises(RateApiClient::UpstreamError) { RateApiClient.get_all_rates }
  end

  test "get_all_rates raises UpstreamError when every entry is invalid" do
    rates = PricingConstants::ALL_COMBINATIONS.map do |combo|
      combo.transform_keys(&:to_s).merge("rate" => 10_000, "hotel" => "MarsResort")
    end
    stub_upstream(status: 200, body: { "rates" => rates })

    assert_raises(RateApiClient::UpstreamError) { RateApiClient.get_all_rates }
  end

  # --- HTTP status mapping ---

  test "get_all_rates raises UnauthorizedError on 401" do
    stub_upstream(status: 401, body: { "error" => "Unauthorized" })

    assert_raises(RateApiClient::UnauthorizedError) { RateApiClient.get_all_rates }
  end

  test "get_all_rates raises UpstreamError on 5xx" do
    stub_upstream(status: 503, body: { "error" => "Service Unavailable" })

    assert_raises(RateApiClient::UpstreamError) { RateApiClient.get_all_rates }
  end

  test "get_all_rates raises QuotaExhaustedError on 429" do
    stub_upstream(status: 429, body: { "error" => "Rate limit exceeded (1000/day)" })

    assert_raises(RateApiClient::QuotaExhaustedError) { RateApiClient.get_all_rates }
  end

  test "get_all_rates raises TimeoutError on timeout" do
    stub_request(:post, "#{RATE_API_URL}/pricing").to_timeout

    assert_raises(RateApiClient::TimeoutError) { RateApiClient.get_all_rates }
  end
end
