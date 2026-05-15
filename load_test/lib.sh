#!/usr/bin/env bash
# Shared helpers for the load_test/ suite.
#
# Why a separate file: each test script needs the same building blocks
# (sane shell options, output formatting, Redis state resets, health checks).
# Centralising them here keeps each test focused on its own hypothesis.
#
# Conventions:
#   - All scripts in this folder run with `set -euo pipefail`. Any unhandled
#     error or unset variable aborts the test. This avoids silent partial
#     passes that produce misleading "✓ PASS" output.
#   - Output goes to stdout for humans; raw artifacts (wrk reports, response
#     bodies) go to results/ for later inspection or attaching to a PR.

set -euo pipefail

# Single canonical URL. All four tests hit the same combination so we can
# isolate behaviour to the cache/lock/quota layers, not parameter handling.
PRICING_URL='http://localhost:3000/api/v1/pricing?period=Summer&hotel=FloatingPointResort&room=SingletonRoom'

# results/ holds wrk reports, response headers, and any per-test metrics.
# Created lazily — committing the directory itself is fine, the contents are
# regenerated on every run.
RESULTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/results"
mkdir -p "$RESULTS_DIR"

# ── Output helpers ──────────────────────────────────────────────
# Cyan timestamp + message. Use for narration ("starting wrk", "snapshot…").
log()   { printf "\033[36m[%s]\033[0m %s\n" "$(date +%H:%M:%S)" "$*"; }
# Green PASS line. Final assertion of a test must call this exactly once.
ok()    { printf "\033[32m✓ PASS\033[0m %s\n" "$*"; }
# Red FAIL line. Caller is expected to `exit 1` after invoking this.
fail()  { printf "\033[31m✗ FAIL\033[0m %s\n" "$*"; }
# 60-char horizontal rule for separating test sections in console output.
hr()    { printf '%.0s─' {1..60}; echo; }

# ── Pre-flight ──────────────────────────────────────────────────
# Verify required CLI tools are installed before starting the test.
# Fails fast with a clear error rather than a cryptic "command not found"
# halfway through a 5-minute run.
#
# Usage: require_tools wrk docker curl
require_tools() {
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || { fail "missing tool: $t"; exit 1; }
  done
}

# ── Redis state helpers ─────────────────────────────────────────
# Wipe all keys in the configured Redis database (cache + lock + quota).
# Use this when a test needs a fully cold start with no inherited state.
# DESTRUCTIVE — only safe in the test container, never run against prod.
reset_redis() {
  docker compose exec -T redis redis-cli FLUSHDB > /dev/null
}

# Wipe only pricing cache keys + lock keys, but preserve the quota counter.
# Used by the quota-cap test (3): we set the counter to 1000 and need a
# cache miss to trigger the next INCR — but FLUSHDB would also reset
# the counter, defeating the whole test.
reset_cache_only() {
  docker compose exec -T redis redis-cli --scan --pattern 'pricing:*' \
    | xargs -r docker compose exec -T redis redis-cli DEL > /dev/null || true
  docker compose exec -T redis redis-cli --scan --pattern 'lock_and_fetch_rate:*' \
    | xargs -r docker compose exec -T redis redis-cli DEL > /dev/null || true
}

# ── Marker helpers (currently unused, kept for future extensions) ──
# Count POST /pricing calls in app logs since a marker line.
# Useful when you can't rely on `--since=Ns` (e.g. clock skew between host
# and container). Plant a marker first, then count log lines after it.
upstream_calls_since() {
  local marker="$1"
  docker compose logs --no-color app 2>&1 \
    | sed -n "/$marker/,\$p" \
    | grep -c 'POST.*\/pricing\b' || true
}

# Plant a unique marker into the app log by requesting a non-existent path.
# The 404 line is harmless and easy to find with grep later.
log_marker() {
  local label="$1"
  local marker="MARKER_${label}_$(date +%s%N)"
  curl -s -o /dev/null "http://localhost:3000/__$marker" || true
  echo "$marker"
}

# ── Health gate ────────────────────────────────────────────────
# Refuse to run a test if the service can't return 200 for a basic request.
# Prevents the "test failed because the app wasn't up" false negative.
# Note: upstream is ~28% flaky (4 known failure patterns documented in
# upstream_behavior.html). One unlucky 502/504 here would block the suite,
# so we retry up to 3 times before giving up.
check_health() {
  for attempt in 1 2 3; do
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' "$PRICING_URL")
    if [[ "$code" == "200" ]]; then return 0; fi
    sleep 1
  done
  fail "service not healthy after 3 attempts (last status: $code from $PRICING_URL)"
  exit 1
}
