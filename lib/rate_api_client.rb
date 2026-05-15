class RateApiClient
  include HTTParty

  base_uri ENV.fetch("RATE_API_URL", "http://localhost:8080")
  headers "Content-Type" => "application/json"

  # Why 5 seconds:
  #   Without a timeout, if the upstream hangs, the request blocks forever
  #   and ties up a Puma worker — eventually all workers are stuck and the
  #   app stops responding.
  #   5s gives upstream enough time to respond normally, but if upstream
  #   is completely down, the worker only waits 5s before giving up —
  #   not blocking other requests for too long.
  #   LockAndFetchRate's timing is based on this 5s:
  #   FOLLOWER_TIMEOUT = 6s (5s + 1s buffer),
  #   UPSTREAM_LOCK_AUTO_EXPIRE = 7s (6s + 1s buffer).
  UPSTREAM_TIMEOUT = 5

  # Top-level shape: rates must be an array of hashes.
  # Per-record details are checked separately so one bad row doesn't reject everything.
  RATE_RESPONSE_SCHEMA = Dry::Schema.JSON do
    required(:rates).array(:hash)
  end

  # Per-record shape + whitelist. Unknown hotel/period/room means we can't
  # serve it anyway, so skip. Rate is `.filled` here and type-checked
  # separately (it can be Integer, Float, or numeric string).
  RATE_RECORD_SCHEMA = Dry::Schema.JSON do
    required(:period).filled(:string, included_in?: PricingConstants::VALID_PERIODS)
    required(:hotel).filled(:string, included_in?: PricingConstants::VALID_HOTELS)
    required(:room).filled(:string, included_in?: PricingConstants::VALID_ROOMS)
    required(:rate).filled
  end

  # Actual upstream response patterns from live testing: see UPSTREAM_BEHAVIOR.md
  #
  # Raised when the upstream returns a recognisable failure.
  # Subclasses let the service layer rescue precisely.
  class Error < StandardError; end
  # HTTP 401 — bad token → client gets 502 Bad Gateway
  class UnauthorizedError < Error; end
  # HTTP 429 — daily token limit hit → client gets 429 Too Many Requests
  class QuotaExhaustedError < Error; end
  # open/read timeout → client gets 504 Gateway Timeout
  class TimeoutError        < Error; end
  # any other non-200 → client gets 502 Bad Gateway
  class UpstreamError       < Error; end

  # Fetch all 36 rate combinations in a single API call.
  # Returns a Hash: { "Summer:FloatingPointResort:SingletonRoom" => 55700, ... }
  # One API call = one quota unit, but fills the entire cache.
  def self.get_all_rates
    token = ENV.fetch("RATE_API_TOKEN") { raise "RATE_API_TOKEN is not set" }

    body = { attributes: PricingConstants::ALL_COMBINATIONS }.to_json

    response = post(
      "/pricing",
      body: body,
      headers: { "token" => token },
      timeout: UPSTREAM_TIMEOUT
    )

    handle_all_rates_response(response)
  rescue Net::OpenTimeout, Net::ReadTimeout
    raise TimeoutError, "Rate API timed out after #{UPSTREAM_TIMEOUT}s"
  end

  # Parse bulk response into a keyed Hash.
  # See UPSTREAM_BEHAVIOR.md for full response examples and pattern numbers.
  #
  # Hybrid validation:
  #   - Whole response unusable (no 'rates' key, not an array, every record bad)
  #     → raise UpstreamError, don't write anything.
  #   - One bad row → log a warning and skip just that row, keep the rest.
  # One bad row shouldn't deny cache to 35 good rows.
  def self.handle_all_rates_response(response)
    case response.code
    when 200
      rates = extract_rates!(response)
      parsed = parse_rate_records(rates)

      if parsed.empty?
        raise UpstreamError, "Upstream returned 200 but no records passed validation (#{rates.size} skipped)"
      end

      log_partial(rates, parsed) if parsed.size < rates.size
      parsed
    when 401
      raise UnauthorizedError, "Upstream rejected token (401)"
    when 429
      # Upstream daily token limit hit — body is {"error":"Rate limit exceeded (1000/day)"}.
      raise QuotaExhaustedError, "Upstream rate limit exceeded (429)"
    else
      raise UpstreamError, "Upstream returned #{response.code}"
    end
  end
  private_class_method :handle_all_rates_response

  # Pull `rates` out of a 200 response, raising if the response shape is unusable.
  # Covers four known bad shapes:
  #   - nil: Test 1 #6 / Test 2 #5: 200 with error body, no `rates` key
  #   - empty array: defensive — controller normally blocks this path
  #   - non-array: e.g. 200 with `"rates": "Failed"`
  #   - array but wrong inner shape: schema catches it
  def self.extract_rates!(response)
    rates = response["rates"]

    case rates
    in nil
      msg = response["message"] || response["error"] || "unexpected body"
      raise UpstreamError, "Upstream returned 200 with error body: #{msg}"
    in []
      raise UpstreamError, "Upstream returned 200 with empty rates"
    in Array
      result = RATE_RESPONSE_SCHEMA.call(rates: rates)
      raise UpstreamError, "Upstream returned 200 with invalid response shape: #{result.errors.to_h}" if result.failure?
    else
      raise UpstreamError, "Upstream returned 200 with unexpected rates type: #{rates.class}"
    end

    rates
  end
  private_class_method :extract_rates!

  def self.log_partial(rates, parsed)
    Rails.logger.warn(
      "event=upstream_partial_response valid=#{parsed.size} invalid=#{rates.size - parsed.size} total=#{rates.size}"
    )
  end
  private_class_method :log_partial

  # Return a Hash of valid records only. Bad rows are logged and skipped.
  def self.parse_rate_records(rates)
    rates.filter_map do |rate_record|
      schema_result = RATE_RECORD_SCHEMA.call(rate_record)
      if schema_result.failure?
        Rails.logger.warn(
          "event=upstream_invalid_record reason=#{schema_result.errors.to_h} record=#{rate_record.inspect}"
        )
        next
      end

      rate_value = positive_numeric(rate_record["rate"])
      if rate_value.nil?
        Rails.logger.warn(
          "event=upstream_invalid_record reason=invalid_rate=#{rate_record["rate"].inspect} record=#{rate_record.inspect}"
        )
        next
      end

      ["#{rate_record["period"]}:#{rate_record["hotel"]}:#{rate_record["room"]}", rate_value]
    end.to_h
  end
  private_class_method :parse_rate_records

  # Returns the value as a positive number, or nil if it isn't one.
  # Accepts Integer, Float, or numeric strings ("100" or "100.50").
  # Rejects zero, negative, non-numeric, and anything else.
  def self.positive_numeric(value)
    num = case value
          when Integer, Float then value
          when String
            if value.match?(/\A-?\d+\z/)
              value.to_i
            elsif value.match?(/\A-?\d+\.\d+\z/)
              value.to_f
            end
          end
    num if num && num.positive?
  end
  private_class_method :positive_numeric
end
