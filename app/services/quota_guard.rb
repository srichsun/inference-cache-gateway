# Local tripwire on top of upstream's 1,000/day cap.
#
# Normal flow: cache (5-min TTL) + bulk fetch → ~288 calls/day, never triggers.
# Fires when something above breaks (parser fail, cache write typo, TTL
# misconfig, Redis restart loop) and every miss bleeds through to upstream.
#
# Buys us:
# #   - Good-citizen behavior: the spec describes upstream's inference as
#     "computationally expensive". Normally the 1,001st call is rejected
#     up front with 429 — upstream never runs the expensive inference for it.
#     But if that limiter ever misconfigures (bug, redeploy, staging quirk),
#     our overflow calls would actually hit the inference — burning real
#     compute. QuotaGuard keeps us honest to the contract regardless of
#     upstream's enforcement state.
#
# Multi-worker safety: Redis INCR is atomic, so two workers can't both read
# 999 and both pass. The key (quota:YYYY-MM-DD) auto-expires at UTC midnight.
#
# Trade-offs:
#   - Cap enforced in two places (upstream & here) — DAILY_LIMIT must track.
#   - ~50 lines for a layer that should never trigger. A minimalist would
#     skip it and trust upstream's 429.
class QuotaGuard
  DAILY_LIMIT = 1_000 # matches the upstream 1,000/day hard limit

  class ExhaustedError < StandardError; end

  # Use one unit of today's upstream quota.
  #   under budget → increment counter, return true
  #   over budget  → raise ExhaustedError
  #
  # Counter key and expire are both based on UTC, independent of Rails
  # Time.zone, so the daily reset stays at UTC midnight regardless of
  # deployment timezone config.
  def self.consume_quota!
    today_utc = Time.now.utc.to_date
    daily_key = "quota:#{today_utc}"
    current_usage = nil

    # .with borrows a connection from the pool and returns it when the block finishes.
    Rails.cache.redis.with do |conn|
      # Redis INCR is atomic — returns the new count after +1, no race condition
      current_usage = conn.incr(daily_key)

      # First call of the day → set the key to expire at UTC midnight
      if current_usage == 1
        midnight_utc = (today_utc + 1).to_time(:utc)
        conn.expireat(daily_key, midnight_utc.to_i)
      end
    end

    if current_usage > DAILY_LIMIT
      raise ExhaustedError, "Daily upstream quota exhausted (#{current_usage}/#{DAILY_LIMIT})"
    end

    true
  end

  # Refund one unit after an upstream 401 — the token was rejected before any
  # processing occurred, so the quota unit should not be spent.
  #
  # Uses a Lua script for atomic check-then-decr: only decrements when the
  # counter is above zero. Without this guard, refunding before any INCR
  # (e.g. burst 401s right after token rotation) would push the counter
  # negative, allowing subsequent INCRs to silently exceed 1000.
  REFUND_LUA = <<~LUA.freeze
    local v = tonumber(redis.call('get', KEYS[1]) or 0)
    if v > 0 then
      return redis.call('decr', KEYS[1])
    else
      return v
    end
  LUA

  def self.refund_quota!
    Rails.cache.redis.with do |conn|
      conn.eval(REFUND_LUA, keys: ["quota:#{Time.now.utc.to_date}"])
    end
  end
end
