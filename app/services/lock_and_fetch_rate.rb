# Heads up: this uses a single Redis. If you ever run it with Sentinel or
# Cluster for HA, you can briefly have two leaders during a primary failover
# (the lock write may not have made it to the replica before failover).
# The proper fix is etcd or Consul — they use Raft so a lost write can't happen.
# Even if two leaders do slip through, QuotaGuard's atomic counter still caps
# daily upstream calls, so the upstream contract holds either way.
#
# Background:
#   Cache entries expire every 5 minutes. At the moment of expiry,
#   many requests can arrive at the same time and all see a cache miss.
#
# Problem:
#   Without coordination, every concurrent cache-miss request calls
#   upstream independently. A burst of 50 requests burns 50 quota
#   units instead of 1 — wasting the daily budget.
#
# Solution:
#   Use a Redis lock (SET NX) to elect one "leader" across all concurrent requests.
#   The leader calls upstream and writes the cache.
#   All other requests ("followers") wait and read the cache once
#   the leader populates it. Result: N concurrent misses = 1 upstream call.

# Timing design:
#   The three values form a chain — each one depends on the previous:
#
#   UPSTREAM_TIMEOUT (5s) < FOLLOWER_TIMEOUT (6s) < UPSTREAM_LOCK_AUTO_EXPIRE (7s)
#
#   Start from UPSTREAM_TIMEOUT (5s, defined in RateApiClient) — the
#   longest a leader can spend calling upstream:
#
#   - FOLLOWER_TIMEOUT (6s): follower gives up after 6s. Why not exactly 5s?
#     The leader could get the upstream response at 4.9s, write cache, but
#     the follower already gave up at 5.0s — wasted the whole wait.
#     1s buffer covers this edge case. If still no result after 6s,
#     something went wrong — stop waiting, return an error.
#
#   - UPSTREAM_LOCK_AUTO_EXPIRE (7s): the lock deletes itself after 7s.
#     Normally `ensure` deletes the lock right away. But if the process
#     crashes hard (e.g. kill -9), `ensure` never runs and the lock is stuck.
#     7s is the safety net: the lock disappears on its own.
#
#     It must be longer than FOLLOWER_TIMEOUT (6s). If it were shorter,
#     the lock would expire while followers are still waiting. Then a new
#     request grabs the lock → becomes a second leader → calls upstream
#     again → wastes another quota unit for the same result.
#
#   - FOLLOWER_POLL_INTERVAL (50ms): how often a follower checks the cache.
#     1ms = too fast, floods Redis with reads.
#     1s = too slow, follower waits up to 1s after the leader is done.
#     50ms = good balance. At most 50ms extra wait, at most 6/0.05 = 120 Redis reads total.
#     which is good.

class LockAndFetchRate
  UPSTREAM_LOCK_AUTO_EXPIRE = 7.seconds
  FOLLOWER_TIMEOUT          = 6.seconds
  FOLLOWER_POLL_INTERVAL    = 0.05

  class TimeoutError < StandardError; end

  # Only delete the lock if its value still matches our lock_owner_id.
  # Runs as one atomic step in Redis — nobody can sneak in between
  # the check and the delete.
  #
  # Without this guard:
  #   t=0  Process A grabs the lock, value = "A"
  #   t=2  Process A is stuck (GC pause, slow network)
  #   t=7  Process A's lock auto-expires
  #   t=8  Process B grabs the lock, value = "B"
  #   t=9  Process A wakes up, runs `ensure` → plain DEL deletes B's lock
  #   t=9  Process C grabs the lock → B and C now both think they're leaders
  #        → two upstream calls for the same work → quota wasted
  RELEASE_LUA = <<~LUA.freeze
    if redis.call('get', KEYS[1]) == ARGV[1] then
      return redis.call('del', KEYS[1])
    else
      return 0
    end
  LUA

  # Try to grab the lock for this operation.
  #   Won the lock  → I'm the leader, execute the block (fetch upstream + write cache)
  #   Lost the lock → I'm a follower, wait for the leader to populate the cache
  #
  # Two keys, two jobs:
  #   lock_key:  one shared key everyone fights over (e.g. "pricing:bulk_fetch").
  #              Only one request wins — that request calls upstream for all 36 combos. The rest wait.
  #   cache_key: the specific rate this request needs (e.g. "pricing:Summer:FloatingPointResort:SingletonRoom").
  #              Followers watch this key and return as soon as the leader writes it.
  def self.call(lock_key, cache_key)
    redis_lock_key = "lock_and_fetch_rate:#{lock_key}"
    # Give every leader a unique ID. We'll use this later to check
    # "is this lock still mine?" before deleting it.
    lock_owner_id = SecureRandom.uuid

    # Use raw Redis SET NX EX, not Rails.cache.write.
    # Rails.cache wraps values with Marshal, so the stored value
    # wouldn't be the plain UUID string — and our Lua check would fail.
    acquired = Rails.cache.redis.with do |conn|
      conn.set(redis_lock_key, lock_owner_id, nx: true, ex: UPSTREAM_LOCK_AUTO_EXPIRE.to_i)
    end

    if acquired
      # Leader: execute the block (fetch upstream + write cache).
      # ensure: always release the lock, even if the block crashes,
      # so followers don't get stuck waiting forever.
      begin
        yield
      ensure
        # Release the lock — but only if the value in Redis is still our lock_owner_id.
        # If it's not (someone else took over for any reason), leave it alone.
        Rails.cache.redis.with do |conn|
          conn.eval(RELEASE_LUA, keys: [redis_lock_key], argv: [lock_owner_id])
        end
      end
    else
      # Follower: someone else is already fetching, just wait for the cache.
      poll_for_result(cache_key)
    end
  end

  # Follower waits here: check cache every 50ms.
  #   Cache has data → leader is done, return the result.
  #   Waited too long → something went wrong, give up with TimeoutError.
  def self.poll_for_result(cache_key)
    waited = 0.0
    while waited < FOLLOWER_TIMEOUT
      sleep(FOLLOWER_POLL_INTERVAL)
      waited += FOLLOWER_POLL_INTERVAL
      result = Rails.cache.read(cache_key)
      return result if result
    end
    raise TimeoutError, "Timed out waiting for cache: #{cache_key}"
  end
  private_class_method :poll_for_result
end
