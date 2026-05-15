#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# run_all.sh — Orchestrator for the load_test/ suite
# ─────────────────────────────────────────────────────────────────────
#
# Runs all four behavioural tests in sequence and prints a final summary.
#
# Order is deliberate (fast → slow):
#   3_quota_cap        ~5s
#   1_singleflight     ~10s
#   4_fail_closed      ~10s
#   2_cache_hit_rate   default 5min (override with DURATION=30s)
#
# Putting the long cache-hit-rate test LAST means a quick smoke run
# (DURATION=30s ./run_all.sh) finishes the fast tests immediately and
# fails fast if any are broken — no waiting 5 minutes only to discover
# test 1 is busted.
#
# Note: we deliberately do NOT use `set -e`. If one test fails, the
# others should still run so the operator gets a complete picture
# instead of stopping at the first red line.

set -uo pipefail
cd "$(dirname "$0")"

PASS=()
FAIL=()

# Run a single test, tagging the result into PASS[] or FAIL[] for
# the summary. We let the test script print its own output; this
# wrapper only tracks pass/fail status.
run() {
  local name="$1"; shift
  echo
  if "$@"; then
    PASS+=("$name")
  else
    FAIL+=("$name")
  fi
}

run "3_quota_cap"      ./3_quota_cap.sh
run "1_singleflight"   ./1_singleflight.sh
run "4_fail_closed"    ./4_fail_closed.sh
# Cache hit rate last because it takes 5 minutes by default.
run "2_cache_hit_rate" ./2_cache_hit_rate.sh

echo
echo "═══════════════════════════════════════════"
echo "Summary"
echo "═══════════════════════════════════════════"
for t in "${PASS[@]:-}"; do [[ -n "$t" ]] && printf "✓ PASS  %s\n" "$t"; done
for t in "${FAIL[@]:-}"; do [[ -n "$t" ]] && printf "✗ FAIL  %s\n" "$t"; done
echo
echo "Results saved in: results/"

# Exit non-zero if anything failed — useful in CI or piping to
# `&& echo "all good"`.
if [[ ${#FAIL[@]} -gt 0 ]]; then
  exit 1
fi
