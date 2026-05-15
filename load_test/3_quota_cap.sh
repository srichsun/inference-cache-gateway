#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# Test 3 — Quota hard cap (atomic INCR safety net)
# ─────────────────────────────────────────────────────────────────────
#
# What we're testing:
#   When the daily counter is at 1000 and a new cache miss arrives,
#   does QuotaGuard's atomic INCR push the counter to 1001 → raise
#   ExhaustedError → return HTTP 429 with Retry-After, WITHOUT calling
#   upstream?
#
# Why this matters:
#   Cache + lock keep us at ~288 calls/day under normal operation, but
#   that's a *probabilistic* guarantee. If the cache layer breaks (TTL
#   misconfig, Redis restart loop, code bug), we lose the upstream
#   contract. QuotaGuard is the deterministic, mathematical guarantee
#   that 1000/day is never exceeded — regardless of failures upstream
#   in the call graph. This test verifies the guarantee actually holds.
#
# Method:
#   1. FLUSHDB to start clean.
#   2. SET quota:YYYY-MM-DD = 1000 directly via redis-cli.
#   3. Snapshot rate-api log line count before.
#   4. Issue ONE request: cache miss → lock acquired → QuotaGuard.consume
#      → INCR returns 1001 → ExhaustedError raised → upstream NOT called.
#   5. Verify HTTP 429 + Retry-After header + zero upstream delta.
#
# Why we set to 1000 (not 999):
#   QuotaGuard checks `if current_usage > 1000`. The Nth INCR returns N.
#   So setting to 1000 means the next INCR returns 1001 → 1001 > 1000
#   → blocked. Setting to 999 would let the 1000th call through (returns
#   1000, which is NOT > 1000) — that's still within budget by design.
#   We want to verify the BLOCKING boundary, hence 1000 → 1001.
#
# Pass criteria:
#   - status == 429
#   - Retry-After header present (lets clients pace retries)
#   - upstream_delta == 0 (the guard prevented the call entirely)
#     upstream_delta = upstream call count after the test - count before

set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

require_tools docker curl

hr
log "Test 3 — Quota hard cap (1001st call → 429)"
hr

check_health
log "wiping all state, then setting quota counter to 1000"
reset_redis

# QuotaGuard uses `Time.zone.today` which formats as YYYY-MM-DD.
# We must match that exact format or the counter we set won't be the
# one the service reads.
QUOTA_KEY="quota:$(date -u +%Y-%m-%d)"
docker compose exec -T redis redis-cli SET "$QUOTA_KEY" 1000 > /dev/null
log "set $QUOTA_KEY = 1000 (next INCR will hit 1001 and exhaust)"

# Capture the upstream call count BEFORE issuing the test request.
# We compare BEFORE/AFTER to detect any leak. (Counting since=Ns is
# unreliable here — the test takes <1s, sub-second log filtering can
# miss the relevant lines.)
BEFORE=$(docker compose logs --no-color rate-api 2>&1 | grep -c 'POST .*pricing' || true)
log "upstream calls before test: $BEFORE"

log "issuing request (should hit cache miss → quota check → 429)"
RESPONSE=$(curl -s -i "$PRICING_URL")
echo "$RESPONSE" | tee "$RESULTS_DIR/3_quota_cap_response.txt"

# Parse the HTTP/1.1 response line and the Retry-After header from
# the raw curl -i output. Use `tr -d '\r'` because HTTP headers carry
# CRLF line endings and shell string compare hates them.
STATUS=$(echo "$RESPONSE" | grep -E '^HTTP/' | awk '{print $2}' | tr -d '\r')
RETRY_AFTER=$(echo "$RESPONSE" | grep -i '^retry-after:' | awk '{print $2}' | tr -d '\r')

AFTER=$(docker compose logs --no-color rate-api 2>&1 | grep -c 'POST .*pricing' || true)
DELTA=$((AFTER - BEFORE))
log "upstream calls after test: $AFTER (delta=$DELTA)"

# Track each invariant separately so a partial failure produces a
# meaningful error message (not just "test failed").
PASS=true
if [[ "$STATUS" != "429" ]]; then
  fail "expected HTTP 429, got $STATUS"
  PASS=false
fi
if [[ -z "$RETRY_AFTER" ]]; then
  fail "missing Retry-After header"
  PASS=false
fi
if [[ "$DELTA" -ne 0 ]]; then
  fail "upstream was called $DELTA time(s) — quota guard leaked"
  PASS=false
fi

{
  echo "status=$STATUS"
  echo "retry_after=$RETRY_AFTER"
  echo "upstream_delta=$DELTA"
} >> "$RESULTS_DIR/3_quota_cap_response.txt"

if $PASS; then
  ok "Quota cap working — 1001st INCR returned 429 with Retry-After=$RETRY_AFTER, upstream untouched"
else
  exit 1
fi

# Important: clear the counter we just maxed out, otherwise subsequent
# tests (and any manual exploration) will keep hitting 429 until UTC
# midnight when the key auto-expires.
log "cleanup: clearing quota counter"
docker compose exec -T redis redis-cli DEL "$QUOTA_KEY" > /dev/null
