#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# Test 1 — Single-flight verification
# ─────────────────────────────────────────────────────────────────────
#
# What we're testing:
#   When 50 clients request the same combination at the same time on a
#   cold cache, does our LockAndFetchRate (Redis SETNX leader election)
#   collapse the storm into a single upstream call?
#
# Why this matters:
#   Without single-flight, N concurrent cache misses each trigger an
#   independent upstream call → quota burns N× faster than necessary.
#   This is the core invariant the lock layer exists to protect.
#
# Method:
#   1. FLUSHDB to guarantee a cold cache (cache + lock + quota all empty).
#   2. wrk -c50 for 5s — 50 concurrent connections hammering the same key.
#   3. Snapshot rate-api logs since 10s ago, count POST /pricing calls.
#
# wrk parameters explained:
#   -t10  : 10 OS threads. We want enough threads to actually utilise
#           50 connections in parallel (5 conns/thread is the sweet spot
#           per wrk's own README).
#   -c50  : 50 simultaneous keep-alive connections — represents the
#           thundering herd scenario at cache expiry.
#   -d5s  : 5 seconds is enough to issue thousands of requests and
#           observe steady-state behaviour, but short enough to fail fast.
#   --latency : enable percentile breakdown (p50/p75/p90/p99) in output.
#
# Pass criteria:
#   - upstream_calls ≤ 5  (perfect single-flight = 1; we allow up to 5
#     because upstream is ~28% flaky — leader can fail, release the lock,
#     next request becomes new leader, retry.
#
#     Why 5 specifically: P(N consecutive failures) = 0.28^N
#       2 fails ≈ 7.8%
#       3 fails ≈ 2.2%
#       4 fails ≈ 0.6%   ← already rare
#       5 fails ≈ 0.17%
#     5 = "tolerate 4 unlucky retries before success" — anything more
#     suggests the lock is broken (parallel leaders), not random flake.
#     Sequential retries are correct behaviour, parallel retries are the bug.)
#   - client/upstream ratio ≥ 100:1  (under 50 concurrent for 5s we
#     expect ~1k+ requests; even with 5 upstream retries that's 200:1.
#     A ratio below 100 means the lock is actively broken.)

set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

require_tools wrk docker curl

hr
log "Test 1 — Single-flight (50 concurrent cold-start)"
hr

check_health
log "wiping cache + quota + lock for cold start"
reset_redis

log "starting wrk: 50 concurrent connections, 10 threads, 5s duration"
WRK_OUT=$(wrk -t10 -c50 -d5s --latency "$PRICING_URL" 2>&1)
echo "$WRK_OUT" | tee "$RESULTS_DIR/1_singleflight_wrk.txt"

# We count POST /pricing on the rate-api container (the actual upstream),
# not the app side. app logs every incoming GET — we
# only care about outbound calls that consumed quota.
# --since=10s captures everything from "wrk start" through "wrk finish"
# without requiring a pre-test marker.
UPSTREAM_HITS=$(docker compose logs --no-color --since=10s rate-api 2>&1 | grep -c 'POST .*pricing' || true)

# Extract total client requests from wrk's summary line, e.g.:
#   "1404 requests in 5.04s, 798.05KB read"
TOTAL_REQS=$(echo "$WRK_OUT" | grep -oE '[0-9]+ requests in' | grep -oE '^[0-9]+')
RATIO=$(awk "BEGIN { printf \"%.1f\", $TOTAL_REQS / $UPSTREAM_HITS }")

log "client requests: $TOTAL_REQS"
log "upstream POST count: $UPSTREAM_HITS"
log "ratio (client:upstream): ${RATIO}:1"

# Persist the metrics alongside wrk output for later review.
{
  echo "client_requests=$TOTAL_REQS"
  echo "upstream_calls=$UPSTREAM_HITS"
  echo "client_to_upstream_ratio=$RATIO"
} >> "$RESULTS_DIR/1_singleflight_wrk.txt"

# See pass criteria explanation in the file header.
if (( UPSTREAM_HITS <= 5 )) && awk "BEGIN { exit !($RATIO >= 100) }"; then
  ok "Single-flight working — $TOTAL_REQS requests served by $UPSTREAM_HITS upstream calls (${RATIO}:1)"
  log "  (multiple upstream calls expected: upstream is ~28% flaky → leader retries on failure)"
else
  fail "Expected ≤5 upstream calls (got $UPSTREAM_HITS) and ratio ≥100:1 (got ${RATIO}:1)"
  exit 1
fi
