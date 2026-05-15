require "test_helper"

module Api
  module V1
    class PricingServiceTest < ActiveSupport::TestCase
      RATE_API_URL = ENV.fetch("RATE_API_URL", "http://rate-api:8080")
      PARAMS       = { period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom" }.freeze

      setup do
        Rails.cache.clear
      end

      def stub_upstream(status:, body:)
        stub_request(:post, "#{RATE_API_URL}/pricing")
          .to_return(status: status, body: body.to_json, headers: { "Content-Type" => "application/json" })
      end

      # Build a full 36-rate bulk response (the format get_all_rates expects).
      # The target combo gets the specified rate; others get 10_000.
      def bulk_response_body(rate: 55_700)
        rates = PricingConstants::ALL_COMBINATIONS.map do |combo|
          r = combo.slice(:period, :hotel, :room)
          if r[:period] == PARAMS[:period] && r[:hotel] == PARAMS[:hotel] && r[:room] == PARAMS[:room]
            r.merge("rate" => rate)
          else
            r.merge("rate" => 10_000)
          end
        end
        { "rates" => rates.map { |r| r.transform_keys(&:to_s) } }
      end

      # Build a bulk response where every rate field is missing (quota exhausted).
      def bulk_response_body_no_rates
        rates = PricingConstants::ALL_COMBINATIONS.map do |combo|
          combo.slice(:period, :hotel, :room).transform_keys(&:to_s)
        end
        { "rates" => rates }
      end

      def run_service
        service = Api::V1::PricingService.new(**PARAMS)
        service.run
        service
      end

      # --- Happy path ---

      test "returns rate and cache_status 'miss' when cache is empty" do
        stub_upstream(status: 200, body: bulk_response_body)

        service = run_service

        assert_predicate service, :valid?
        assert_equal 55_700, service.result
        assert_equal "miss", service.cache_status
        assert_kind_of Numeric, service.upstream_latency_ms
      end

      test "returns cached rate and cache_status 'hit' when cache has data" do
        RateCache.write_all("Summer:FloatingPointResort:SingletonRoom" => 55_700)

        service = run_service

        assert_predicate service, :valid?
        assert_equal 55_700, service.result
        assert_equal "hit", service.cache_status
        assert_nil service.upstream_latency_ms
      end

      test "writes all 36 rates to cache after a successful upstream call" do
        stub_upstream(status: 200, body: bulk_response_body)

        run_service

        # The requested combo should be cached
        cached = RateCache.read(**PARAMS)

        assert_equal 55_700, cached

        # A different combo should also be cached (bulk fetch fills everything)
        other = RateCache.read(period: "Winter", hotel: "GitawayHotel", room: "BooleanTwin")

        assert_equal 10_000, other
      end

      # --- Fail path — error mapping ---

      test "maps QuotaGuard::ExhaustedError to too_many_requests" do
        QuotaGuard::DAILY_LIMIT.times { QuotaGuard.consume_quota! }

        service = run_service

        assert_not service.valid?
        err = service.errors.first

        assert_equal :too_many_requests, err[:status]
        assert_includes err[:message], "quota"
      end

      test "maps RateApiClient::UnauthorizedError to bad_gateway" do
        stub_upstream(status: 401, body: { "error" => "Unauthorized" })

        service = run_service

        assert_not service.valid?
        err = service.errors.first

        assert_equal :bad_gateway, err[:status]
        assert_includes err[:message], "authentication"
      end

      test "maps upstream 200 with missing rate field to bad_gateway" do
        stub_upstream(status: 200, body: bulk_response_body_no_rates)

        service = run_service

        assert_not service.valid?
        err = service.errors.first

        assert_equal :bad_gateway, err[:status]
        assert_includes err[:message], "Upstream error"
      end

      test "maps upstream 200 with error body to bad_gateway" do
        stub_upstream(status: 200, body: { "message" => "Failed to process rates", "status" => "error" })

        service = run_service

        assert_not service.valid?
        err = service.errors.first

        assert_equal :bad_gateway, err[:status]
        assert_includes err[:message], "Upstream error"
      end

      test "maps upstream 429 to too_many_requests via QuotaExhaustedError" do
        stub_upstream(status: 429, body: { "error" => "Rate limit exceeded (1000/day)" })

        service = run_service

        assert_not service.valid?
        err = service.errors.first

        assert_equal :too_many_requests, err[:status]
        assert_includes err[:message], "quota"
      end

      test "maps RateApiClient::TimeoutError to gateway_timeout" do
        stub_request(:post, "#{RATE_API_URL}/pricing").to_timeout

        service = run_service

        assert_not service.valid?
        err = service.errors.first

        assert_equal :gateway_timeout, err[:status]
        assert_includes err[:message], "timed out"
      end

      test "maps LockAndFetchRate::TimeoutError to gateway_timeout" do
        LockAndFetchRate.stub(:call, ->(_lock_key, _cache_key, &_blk) { raise LockAndFetchRate::TimeoutError, "follower timed out" }) do
          service = run_service

          assert_not service.valid?
          err = service.errors.first

          assert_equal :gateway_timeout, err[:status]
          assert_includes err[:message], "timed out"
        end
      end

      test "maps StandardError to internal_server_error" do
        LockAndFetchRate.stub(:call, ->(_lock_key, _cache_key, &_blk) { raise StandardError, "something unexpected" }) do
          service = run_service

          assert_not service.valid?
          err = service.errors.first

          assert_equal :internal_server_error, err[:status]
          assert_includes err[:message], "Unexpected"
        end
      end

      test "maps RateApiClient::UpstreamError to bad_gateway" do
        stub_upstream(status: 503, body: { "error" => "Service Unavailable" })

        service = run_service

        assert_not service.valid?
        err = service.errors.first

        assert_equal :bad_gateway, err[:status]
        assert_includes err[:message], "Upstream error"
      end

      # --- Edge / Boundary ---

      test "cache_status is 'miss' and upstream_latency_ms is set when upstream responds" do
        stub_upstream(status: 200, body: bulk_response_body)

        service = run_service

        assert_equal "miss", service.cache_status
        assert_predicate service.upstream_latency_ms, :positive?, "upstream_latency_ms should be positive"
      end

      test "cache_status is 'hit' and upstream_latency_ms is nil when cache has data" do
        RateCache.write_all("Summer:FloatingPointResort:SingletonRoom" => 55_700)

        service = run_service

        assert_equal "hit", service.cache_status
        assert_nil service.upstream_latency_ms, "upstream_latency_ms should be nil on cache hit"
      end

      # --- Isolation ---

      test "errors array contains exactly one error per failure" do
        stub_upstream(status: 401, body: { "error" => "Unauthorized" })

        service = run_service

        assert_equal 1, service.errors.length
      end

      test "each error has status, message, and detail keys" do
        stub_upstream(status: 401, body: { "error" => "Unauthorized" })

        service = run_service

        err = service.errors.first

        assert err.key?(:status),  "error should have :status"
        assert err.key?(:message), "error should have :message"
        assert err.key?(:detail),  "error should have :detail"
      end
    end
  end
end
