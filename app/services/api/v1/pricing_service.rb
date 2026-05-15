# Background:
#   The original PricingService did everything in one method:
#     - HTTP call:       RateApiClient.get_rate(...)
#     - Status check:    rate.success?
#     - JSON parsing:    JSON.parse(rate.body)
#     - Field extraction: parsed_rate['rates'].detect { ... }&.dig('rate')
#     - Error handling:  errors << rate.body['error']
#   These are five different concerns (HTTP, parsing, data extraction,
#   error handling, business logic) all mixed in one place.
#
#   On the controller side, errors were rendered with a fixed status:
#     render json: { error: service.errors.join(', ') }, status: :bad_request
#   So no matter what went wrong, the client always got 400 Bad Request.
#
# Problem:
#   1. No status differentiation — upstream 401 (auth failure), 503
#      (server down), and timeout all returned 400 Bad Request to the
#      client. 400 means "your request is wrong", which is misleading
#      when the actual problem is on the server side. The client can't
#      tell whether to fix the request or just retry later.
#   2. Silent failures — when upstream returns 200 but omits the rate
#      field (quota exhausted), the old code returned nil with no error.
#   3. No caching or quota protection — every request hit upstream.
#
# Refactor:
#   - RateApiClient now owns HTTP + JSON + field extraction, and raises
#     typed exceptions (UnauthorizedError, TimeoutError, etc.).
#     It returns a clean Integer on success — callers never touch JSON.
#   - PricingService rescues each exception type and maps it to the
#     correct HTTP status + clear message (502, 504, 429).
#     The controller just reads that hash and renders — no business logic.
#   - Added RateCache (5-min TTL) and QuotaGuard (1,000/day hard cap)
#     to reduce upstream calls and protect the daily budget.
module Api
  module V1
    class PricingService < BaseService
      def initialize(period:, hotel:, room:)
        super()
        @period = period
        @hotel  = hotel
        @room   = room
      end

      # Exposed for Lograge so every request log line includes:
      #   cache_status       — "hit" or "miss": is the cache protecting quota?
      #   upstream_latency_ms — how fast is upstream? nil on cache hit.
      # These two fields let you build dashboards and alerts in production
      # (e.g. cache hit rate dropping, upstream getting slower).
      attr_reader :cache_status, :upstream_latency_ms

      def run
        # 1. Cache has data → return it, skip upstream call
        cached = RateCache.read(period: @period, hotel: @hotel, room: @room)
        if cached
          @cache_status = "hit"
          @result = cached
          return
        end

        # 2. Cache miss — instead of fetching just 1 rate, we fetch all 36
        #    at once so the entire cache is filled in one API call.
        #    If many requests miss the cache at the same time, only one
        #    actually calls the API (the "leader"). Everyone else waits
        #    for the leader to finish, then reads from cache.
        #    This way we only spend 1 quota unit no matter how many
        #    requests are waiting.
        @cache_status = "miss"

        # lock_key  = "pricing:bulk_fetch": the leader holds this lock, calls upstream once to fetch all 36 rates, then writes them to cache
        # cache_key = rate_cache_key: the specific rate this request needs — followers poll this key until the leader writes it
        rate_cache_key = RateCache.cache_key(period: @period, hotel: @hotel, room: @room)

        @result = LockAndFetchRate.call("pricing:bulk_fetch", rate_cache_key) do
          QuotaGuard.consume_quota!
          start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          all_rates = RateApiClient.get_all_rates
          @upstream_latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round(1)
          RateCache.write_all(all_rates)
          all_rates["#{@period}:#{@hotel}:#{@room}"]
        end
      rescue QuotaGuard::ExhaustedError => e
        # Daily budget used up; tell the client to retry tomorrow → 429
        errors << { status: :too_many_requests, message: "Daily quota reached — requests resume at midnight UTC",
                    detail: e.message }
      rescue RateApiClient::UnauthorizedError => e
        # 401 from upstream = server-side config issue, not a client mistake → 502
        # Refund the quota unit — upstream rejected before processing anything.
        QuotaGuard.refund_quota!
        errors << { status: :bad_gateway,           message: "Upstream authentication failed", detail: e.message }
      rescue RateApiClient::QuotaExhaustedError => e
        # Upstream rate limit hit (HTTP 429) → 429
        errors << { status: :too_many_requests,     message: "Upstream API quota exhausted — token limit reached",
                    detail: e.message }
      rescue LockAndFetchRate::TimeoutError => e
        # Follower waited too long for the leader to populate cache → 504
        errors << { status: :gateway_timeout,       message: "Request timed out waiting for upstream result",
                    detail: e.message }
      rescue RateApiClient::TimeoutError => e
        # Upstream too slow; client may safely retry later → 504
        errors << { status: :gateway_timeout,       message: "Upstream timed out",             detail: e.message }
      rescue RateApiClient::UpstreamError => e
        # Any other upstream failure → 502
        errors << { status: :bad_gateway,           message: "Upstream error",                 detail: e.message }
      rescue StandardError => e
        # Unexpected error — should be alertable → 500
        errors << { status: :internal_server_error, message: "Unexpected error",               detail: e.message }
      end
    end
  end
end
