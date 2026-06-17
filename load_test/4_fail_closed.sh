#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# Test 4 — Fail-closed when Redis dies
# ─────────────────────────────────────────────────────────────────────
#
# What we're testing:
#   When Redis is unreachable (cache + lock + quota all dead), does the
#   service refuse to serve traffic — or does it accidentally bypass
#   protection layers and start hammering upstream directly?
#
# Why this matters:
#   "Fail-closed" is an explicit design decision: every dependency
#   failure routes to a 5xx response, never a leaked upstream call.
#   The trade-off is service availability (we return 5xx instead of
#   "best-effort" stale data), in exchange for the upstream contract
#   being preserved. For a proxy, that's the right priority.
#
# Method:
#   1. Snapshot rate-api log lines BEFORE the test.
#   2. `docker compose stop redis` — simulate hard infrastructure failure.
#   3. Issue 5 requests in sequence (5 is enough to expose flapping or
#      racy fail-open behaviour without spending too long).
#   4. Check every response is 5xx AND upstream call count didn't move.
#   5. Restart Redis, wait briefly, verify the service auto-recovers.
#
# Why 5 requests not 1:
#   A single request could pass by luck (e.g. last cached connection in
#   the pool). 5 spaced requests force the connection pool to repeatedly
#   re-attempt and fail. If even one slips through to upstream, that's
#   the bug we're hunting.
#
# Why we measure recovery:
#   "Fail-closed" is only acceptable if it's transient — the service
#   must come back automatically when the dependency returns. If a
#   manual restart is needed, that's a different (worse) failure mode
#   that ops would notice.
#
# Pass criteria:
#   - all 5 responses are 5xx
#   - upstream_delta == 0 (no calls leaked through)
#   - post-recovery request returns 200

set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

require_tools docker curl

hr
log "Test 4 — Fail-closed (Redis offline)"
hr

check_health
log "snapshot upstream call count"
BEFORE=$(docker compose logs --no-color rate-api 2>&1 | grep -c 'POST .*pricing' || true)
log "upstream calls before: $BEFORE"

log "stopping redis"
docker compose stop redis > /dev/null
# Wait until Redis is actually unreachable from the app — polling beats
# a fixed sleep on slow machines / CI. Give up after 10s as a safety net.
for i in {1..10}; do
  if ! docker compose exec -T redis redis-cli ping 2>/dev/null | grep -q PONG; then break; fi
  sleep 1
done

# Issue 5 sequential requests. Sequential (not parallel) so we can
# inspect each status individually — a parallel batch would obscure
# whether all 5 failed for the same reason or different ones.
log "sending 5 requests with Redis down"
declare -a STATUSES=()
for i in {1..5}; do
  STATUS=$(curl -s -o /dev/null -w '%{http_code}' "$PRICING_URL")
  STATUSES+=("$STATUS")
  log "  req $i → HTTP $STATUS"
done

AFTER=$(docker compose logs --no-color rate-api 2>&1 | grep -c 'POST .*pricing' || true)
DELTA=$((AFTER - BEFORE))
log "upstream calls after: $AFTER (delta=$DELTA)"

PASS=true

# Every status must be 5xx. We accept any 5xx (502/503/504) because the
# specific code depends on which layer raises first when Redis is down
# (RateCache.read raise → rescue StandardError → 500, or LockAndFetchRate
# timeout → 504). Any 5xx satisfies fail-closed; only 2xx would fail.
for s in "${STATUSES[@]}"; do
  if [[ ! "$s" =~ ^5 ]]; then
    fail "expected 5xx, got $s"
    PASS=false
  fi
done

# Upstream must not have been called even once. This is the critical
# invariant — the WHOLE POINT of fail-closed is to never leak.
if [[ "$DELTA" -ne 0 ]]; then
  fail "upstream was called $DELTA time(s) — fail-closed leaked"
  PASS=false
fi

{
  echo "statuses=${STATUSES[*]}"
  echo "upstream_delta=$DELTA"
} > "$RESULTS_DIR/4_fail_closed.txt"

# Recovery: bring Redis back and verify the service heals itself.
# Poll until Redis accepts connections (works on slow machines too).
log "restarting redis"
docker compose start redis > /dev/null
for i in {1..15}; do
  if docker compose exec -T redis redis-cli ping 2>/dev/null | grep -q PONG; then
    log "redis ready after ${i}s"
    break
  fi
  sleep 1
done
log "verifying service recovers"
RECOVERY=$(curl -s -o /dev/null -w '%{http_code}' "$PRICING_URL")
log "post-recovery status: HTTP $RECOVERY"
echo "post_recovery=$RECOVERY" >> "$RESULTS_DIR/4_fail_closed.txt"

if [[ "$RECOVERY" != "200" ]]; then
  fail "service did not recover after Redis restart (got HTTP $RECOVERY)"
  PASS=false
fi

if $PASS; then
  ok "Fail-closed working — all 5 requests 5xx, 0 upstream leakage, service recovered after restart"
else
  exit 1
fi
