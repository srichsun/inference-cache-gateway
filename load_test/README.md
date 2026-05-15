# Load & Chaos Test Suite

The tests in `test/` prove the code is correct using fakes (fake upstream, no real Redis). These tests start the real system and prove it actually behaves correctly when 50 requests hit at once, when Redis dies, when the quota runs out — the four promises the design has to keep.

## How it differs from `test/`

| `test/` (Rails minitest) | `load_test/` (this folder) |
|---|---|
| Runs on every commit | Run by hand against a running stack |
| Fakes the upstream | Hits the real upstream rate API |
| Tests one piece at a time | Tests the whole thing together |
| Goal: every line of code is exercised | Goal: 4 system-level promises are kept |

## Setup

```bash
brew install wrk                # tool that fires lots of requests at a URL
docker compose up -d --build    # starts the stack (run from project root)
```

## Run everything

```bash
cd load_test
chmod +x *.sh
./run_all.sh
```

Each test prints `✓ PASS` / `✗ FAIL` and saves raw output to `results/`.

## What each test does

| Script | What it proves | How long |
|---|---|---|
| `1_singleflight.sh` | 50 requests at once with empty cache → only 1 upstream call (we allow up to 5 because upstream is flaky) | ~10s |
| `2_cache_hit_rate.sh` | 5 min of normal traffic → ≥99% of requests come from cache | 5 min (`DURATION=30s` for fast) |
| `3_quota_cap.sh` | When today's counter hits 1000 → return HTTP 429 with `Retry-After`; upstream is never called | ~5s |
| `4_fail_closed.sh` | Kill Redis → every request returns 5xx, zero upstream calls; service recovers when Redis comes back | ~15s |

<sub>**Why these durations** — each test runs only as long as it takes to prove its invariant.
&nbsp;&nbsp;• Test 1 (5s): captures the cold-start burst; once cache fills, extra time adds nothing.
&nbsp;&nbsp;• Test 2 (5 min): spans one full TTL window so cache expires exactly once — shorter runs let the cold-start miss skew the hit rate.
&nbsp;&nbsp;• Test 3 (~5s): no load needed — set counter to 1000, send 1 request, expect 429.
&nbsp;&nbsp;• Test 4 (~15s): kill Redis → verify blocked → restart → verify auto-recovery.</sub>

## Quick check (1 minute) — a smoke test

```bash
DURATION=30s ./run_all.sh
```

Shortens the cache test from 5 min to 30 sec — total ~1 minute. Smoke test = the fastest, roughest check that the suite still runs after a refactor. Doesn't prove correctness, just proves nothing exploded.

## Reading the output

Files in `results/`:

| File | What's inside |
|---|---|
| `1_singleflight_wrk.txt` | wrk report + `upstream_calls=N`, `client_to_upstream_ratio=X` |
| `2_cache_hit_rate_wrk.txt` | wrk report + `hits=`, `misses=`, `hit_rate_pct=` |
| `3_quota_cap_response.txt` | Full HTTP response + `status=`, `retry_after=`, `upstream_delta=` |
| `4_fail_closed.txt` | `statuses=...`, `upstream_delta=`, `post_recovery=` |

## When something breaks

**`missing tool: wrk`** — Install with `brew install wrk` (or `apt-get` on Linux).

**`service not healthy after 3 attempts`** — Check `docker compose ps` and `docker compose logs app`. The upstream is ~28% flaky; the health check retries 3 times to tolerate random failures. If every retry fails, the container itself is broken.

**Test 2 says `no cache_status entries found`** — Lograge isn't writing `cache_status` to logs. Check `config/initializers/lograge.rb` and `controller.rb#append_info_to_payload`.

**Test 3 leaves the service stuck on 429** — The cleanup at the end of test 3 should reset the counter. If you killed the test mid-flight, run `docker compose exec redis redis-cli FLUSHDB` to clear it.

**Test 4 says `service did not recover`** — Redis sometimes takes more than 3 seconds to accept connections after restart. Try the test again; if it keeps failing, bump the `sleep 3` line after `docker compose start redis`.
