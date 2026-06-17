require "test_helper"

module Api
  module V1
    class PricingControllerTest < ActionDispatch::IntegrationTest
      RATE_API_URL  = ENV.fetch("RATE_API_URL", "http://rate-api:8080")
      PRICING_PATH  = "/pricing".freeze

      setup do
        # Each test starts with empty cache to avoid cross-test pollution
        Rails.cache.clear
      end

      # Stub the upstream HTTP call at the socket layer via WebMock.
      # This is more realistic than stubbing RateApiClient directly
      # because it exercises timeout handling, headers, and error parsing.
      def stub_upstream(status:, body:)
        stub_request(:post, "#{RATE_API_URL}#{PRICING_PATH}")
          .to_return(status: status, body: body.to_json, headers: { "Content-Type" => "application/json" })
      end

      # Build a full 36-rate bulk response.
      # The target combo gets the specified rate; others get 10_000.
      def bulk_response_body(rate: 55_700)
        rates = PricingConstants::ALL_COMBINATIONS.map do |combo|
          r = combo.slice(:period, :hotel, :room)
          if r[:period] == "Summer" && r[:hotel] == "FloatingPointResort" && r[:room] == "SingletonRoom"
            r.merge("rate" => rate)
          else
            r.merge("rate" => 10_000)
          end
        end
        { "rates" => rates.map { |r| r.transform_keys(&:to_s) } }
      end

      # Build a bulk response where every rate field is missing (intermittent upstream error).
      def bulk_response_body_no_rates
        rates = PricingConstants::ALL_COMBINATIONS.map do |combo|
          combo.slice(:period, :hotel, :room).transform_keys(&:to_s)
        end
        { "rates" => rates }
      end

      # --- Happy path ---

      test "should get pricing with all parameters" do
        stub_upstream(status: 200, body: bulk_response_body)

        get api_v1_pricing_url, params: { period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom" }

        assert_response :success
        assert_equal "application/json", @response.media_type
        assert_equal 55_700, JSON.parse(@response.body)["rate"]
      end

      # --- Fail path — invalid client input ---

      test "should return error when no parameters are provided" do
        get api_v1_pricing_url

        assert_response :bad_request
        assert_includes JSON.parse(@response.body)["error"], "Missing required parameters"
      end

      test "should return error when parameters are empty strings" do
        get api_v1_pricing_url, params: { period: "", hotel: "", room: "" }

        assert_response :bad_request
        assert_includes JSON.parse(@response.body)["error"], "Missing required parameters"
      end

      test "should reject invalid period" do
        get api_v1_pricing_url, params: { period: "summer-2024", hotel: "FloatingPointResort", room: "SingletonRoom" }

        assert_response :bad_request
        assert_includes JSON.parse(@response.body)["error"], "Invalid period"
      end

      test "should reject invalid hotel" do
        get api_v1_pricing_url, params: { period: "Summer", hotel: "InvalidHotel", room: "SingletonRoom" }

        assert_response :bad_request
        assert_includes JSON.parse(@response.body)["error"], "Invalid hotel"
      end

      test "should reject invalid room" do
        get api_v1_pricing_url, params: { period: "Summer", hotel: "FloatingPointResort", room: "InvalidRoom" }

        assert_response :bad_request
        assert_includes JSON.parse(@response.body)["error"], "Invalid room"
      end

      test "should return 400 when required parameters are missing" do
        get api_v1_pricing_url, params: { period: "Summer" }

        assert_response :bad_request
        assert_includes JSON.parse(@response.body)["error"], "Missing required parameters"
      end

      # --- Fail path — upstream failures ---

      test "should return 502 when upstream rejects token" do
        stub_upstream(status: 401, body: { "error" => "Unauthorized" })

        get api_v1_pricing_url, params: { period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom" }

        assert_response :bad_gateway
        assert_includes JSON.parse(@response.body)["error"], "authentication failed"
      end

      test "should return 502 when upstream returns 200 with missing rate field" do
        stub_upstream(status: 200, body: bulk_response_body_no_rates)

        get api_v1_pricing_url, params: { period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom" }

        assert_response :bad_gateway
        assert_includes JSON.parse(@response.body)["error"], "Upstream error"
      end

      test "should return 429 with Retry-After header when daily quota guard triggers" do
        # Burn through QuotaGuard budget so the next call is blocked before hitting upstream
        QuotaGuard::DAILY_LIMIT.times { QuotaGuard.consume_quota! }

        # No WebMock stub needed — QuotaGuard blocks before any HTTP call is made
        get api_v1_pricing_url, params: { period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom" }

        assert_response :too_many_requests
        assert_includes JSON.parse(@response.body)["error"], "quota"
        assert_predicate @response.headers["Retry-After"], :present?,
                         "Retry-After header should tell client when quota resets"
      end

      test "should return 504 when upstream times out" do
        stub_request(:post, "#{RATE_API_URL}#{PRICING_PATH}").to_timeout

        get api_v1_pricing_url, params: { period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom" }

        assert_response :gateway_timeout
        assert_includes JSON.parse(@response.body)["error"], "timed out"
      end

      test "should return 502 when upstream returns 5xx" do
        stub_upstream(status: 503, body: { "error" => "Service Unavailable" })

        get api_v1_pricing_url, params: { period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom" }

        assert_response :bad_gateway
        assert_includes JSON.parse(@response.body)["error"], "Upstream error"
      end

      # --- Isolation — every error response has the same JSON shape ---

      test "all error responses share { error: String } shape when client input is invalid" do
        get api_v1_pricing_url
        body = JSON.parse(@response.body)

        assert body.key?("error"), "response should have 'error' key"
        assert_kind_of String, body["error"]
        assert_not body.key?("rate"), "error response should not contain 'rate'"
      end

      test "all error responses share { error: String } shape when upstream fails" do
        stub_upstream(status: 503, body: { "error" => "Service Unavailable" })
        get api_v1_pricing_url, params: { period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom" }
        body = JSON.parse(@response.body)

        assert body.key?("error"), "response should have 'error' key"
        assert_kind_of String, body["error"]
        assert_not body.key?("rate"), "error response should not contain 'rate'"
      end

      test "Retry-After header value is between 0 and 86400 when quota is exhausted" do
        QuotaGuard::DAILY_LIMIT.times { QuotaGuard.consume_quota! }
        get api_v1_pricing_url, params: { period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom" }

        retry_after = @response.headers["Retry-After"].to_i

        assert_predicate retry_after, :positive?, "Retry-After should be positive"
        assert_operator retry_after, :<=, 86_400, "Retry-After should not exceed 24 hours"
      end

      test "success response has { rate: Integer } shape and no error key" do
        stub_upstream(status: 200, body: bulk_response_body)
        get api_v1_pricing_url, params: { period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom" }
        body = JSON.parse(@response.body)

        assert body.key?("rate"), "success response should have 'rate' key"
        assert_kind_of Integer, body["rate"]
        assert_not body.key?("error"), "success response should not contain 'error'"
      end

      # --- Cache behaviour ---

      test "cache hit returns cached rate without calling upstream when entry exists" do
        # Pre-populate cache
        RateCache.write_all("Summer:FloatingPointResort:SingletonRoom" => 55_700)

        # No stub registered — WebMock will blow up if any HTTP call is made,
        # so a passing test proves the response came from cache, not upstream.
        get api_v1_pricing_url, params: { period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom" }

        assert_response :success
        assert_equal 55_700, JSON.parse(@response.body)["rate"]
      end

      test "cache miss calls upstream and stores the result when no cache entry exists" do
        stub_upstream(status: 200, body: bulk_response_body)

        get api_v1_pricing_url, params: { period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom" }

        assert_response :success

        # Verify cache was populated
        cached = RateCache.read(period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom")

        assert_equal 55_700, cached
      end
    end
  end
end
