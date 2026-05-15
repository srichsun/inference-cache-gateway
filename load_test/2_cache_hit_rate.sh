#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# Test 2 — Cache hit rate under sustained traffic
# ─────────────────────────────────────────────────────────────────────
#
# What we're testing:
#   Under steady traffic, what fraction of requests are served from cache?
#   The bulk-fetch design fills all 36 keys per upstream call, so within
#   a 5-min TTL window we expect at most one miss per window.
#
# Why this matters:
#   The whole architecture exists because 10,000 user requests/day must
#   be served from a 1,000-call upstream budget. A hit rate below ~90%
#   means caching isn't doing its job and the math doesn't work.
#
# Method:
#   1. FLUSHDB → cold start (so the first request is a miss; we want it
#      counted in the denominator to reflect realistic operation).
#   2. wrk -c20 for 5min — moderate sustained load (not a stress test).
#   3. Tally cache_status="hit" vs "miss" from app's Lograge
#      JSON output for the test window.
#
# wrk parameters explained:
#   -c20 : 20 concurrent connections. Lower than test 1 because here we
#          care about steady-state behaviour, not the cold-start burst.
#          20 × 5 min ≈ 6,000+ requests, plenty of statistical signal.
#   -d5m : Default 5 minutes. The 5-min cache TTL means a single miss
#          window happens once during this run, so total misses ≈ 1.
#          Shorter durations underestimate hit rate (the cold-start miss
#          dominates the sample).
#
# Override duration for quick smoke-testing:
#   DURATION=30s ./2_cache_hit_rate.sh
#
# Pass criteria:
#   - hit_rate ≥ 99%  (theoretical max at 1 RPS = 299/300 ≈ 99.67%
#     since 1 miss per 5min window across 300 requests. At higher RPS
#     the same 1 miss spreads over more requests → approaches 99.99%.
#     We set 99% as a practical floor accounting for occasional upstream
#     flakes that cause re-fetches.)

set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

require_tools wrk docker curl

hr
log "Test 2 — Cache hit rate (sustained traffic)"
hr

check_health
log "wiping cache + quota for fresh measurement window"
reset_redis

DURATION="${DURATION:-5m}"     # default 5 minutes; override with env var
CONCURRENCY="${CONCURRENCY:-20}"

log "starting wrk: ${CONCURRENCY} concurrent for ${DURATION}"
log "(reduce duration with: DURATION=30s ./2_cache_hit_rate.sh)"

WRK_OUT=$(wrk -t10 -c"${CONCURRENCY}" -d"${DURATION}" --latency "$PRICING_URL" 2>&1)
echo "$WRK_OUT" | tee "$RESULTS_DIR/2_cache_hit_rate_wrk.txt"

log "tallying cache_status from app logs"

# We rely on Lograge emitting a single JSON line per request with
#   "cache_status":"hit"  or  "cache_status":"miss"
# `--since=$DURATION` keeps us inside the test window (don't count
# requests from prior runs).
HITS=$(docker compose logs --no-color --since="${DURATION}" app 2>&1 \
  | grep -oE '"cache_status":"hit"' | wc -l | tr -d ' ')
MISSES=$(docker compose logs --no-color --since="${DURATION}" app 2>&1 \
  | grep -oE '"cache_status":"miss"' | wc -l | tr -d ' ')
TOTAL=$((HITS + MISSES))

# Sanity check: if Lograge is misconfigured or the duration was too
# short for any traffic to land in logs, total will be 0 and the ratio
# would be undefined (divide by zero). Fail loudly so the user fixes
# config rather than seeing a misleading "PASS".
if [[ "$TOTAL" -eq 0 ]]; then
  fail "no cache_status entries found in logs (Lograge misconfigured? extend DURATION?)"
  exit 1
fi

RATE=$(awk "BEGIN { printf \"%.2f\", ($HITS / $TOTAL) * 100 }")
log "hits=$HITS misses=$MISSES total=$TOTAL hit_rate=${RATE}%"

{
  echo "hits=$HITS"
  echo "misses=$MISSES"
  echo "total=$TOTAL"
  echo "hit_rate_pct=$RATE"
} >> "$RESULTS_DIR/2_cache_hit_rate_wrk.txt"

# awk treats `exit !(condition)` as: exit 0 if true, 1 if false.
# This is the standard idiom for floating-point comparisons in shell.
if awk "BEGIN { exit !($RATE >= 99) }"; then
  ok "Cache hit rate ${RATE}% (≥99% target met)"
else
  fail "Cache hit rate ${RATE}% (below 99%)"
  exit 1
fi
