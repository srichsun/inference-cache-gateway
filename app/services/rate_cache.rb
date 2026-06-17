# Background:
#   The upstream rate API is expensive (1,000 calls/day limit).
#   The same (period, hotel, room) combination returns the same rate
#   for a while, so repeated calls within a short window are wasteful.
#
# Problem:
#   Without caching, every incoming request triggers an upstream call.
#   At 10,000 requests/day we'd blow through the 1,000-call quota
#   very fast.
#
# Solution:
#   Cache each rate by (period, hotel, room) with a 5-minute TTL.
#   Within that window, all requests for the same combo are served
#   from cache — zero upstream calls. Only the first request after
#   expiry hits upstream.
class RateCache
  TTL = 5.minutes

  # Build a namespaced cache key from the three pricing dimensions.
  def self.cache_key(period:, hotel:, room:)
    "pricing:#{period}:#{hotel}:#{room}"
  end

  # Read a cached rate. Returns Integer or nil (cache miss).
  def self.read(period:, hotel:, room:)
    Rails.cache.read(cache_key(period: period, hotel: hotel, room: room))
  end

  # Write all rates from a bulk fetch into the cache.
  # rates_hash: { "Summer:FloatingPointResort:SingletonRoom" => 55700, ... }
  def self.write_all(rates_hash)
    rates_hash.each do |composite_key, rate|
      Rails.cache.write("pricing:#{composite_key}", rate, expires_in: TTL)
    end
  end
end
