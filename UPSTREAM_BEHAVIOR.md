# Upstream Rate-API: Observed Behavior & Error Handling

Findings from two live test runs against the upstream rate API.
Run `upstream_test.rb [single|bulk]` any time the upstream changes to refresh this file.

---

## Test 1 — Single rate (1001 calls)

Date: 2026-05-02 | 1 combination per request
Log: `single_upstream_test.log`

| # | Count | Pattern |
|---|---|---|
| 1 |   631 | HTTP 200 \| ok — rate as Integer |
| 2 |    81 | HTTP 200 \| ok — rate as String |
| 3 |    74 | HTTP 500 \| `{"error":"An unexpected internal error occurred"}` |
| 4 |    73 | HTTP 200 \| rate field absent from response |
| 5 |    71 | TIMEOUT |
| 6 |    70 | HTTP 200 \| error body — `{"message":"Failed to process rates...","status":"error"}` |
| 7 |     1 | HTTP 429 \| `{"error":"Rate limit exceeded (1000/day)"}` |

---

## Test 2 — Bulk rates (1001 calls)

Date: 2026-05-02 | all 36 combinations per request
Log: `bulk_upstream_test.log`

| # | Count | Pattern |
|---|---|---|
| 1 |   662 | HTTP 200 \| ok — all 36 rates as Integer |
| 2 |    74 | TIMEOUT |
| 3 |    74 | HTTP 200 \| all 36 entries rate field absent from response |
| 4 |    66 | HTTP 200 \| ok — all 36 rates as String |
| 5 |    65 | HTTP 200 \| error body — `{"message":"Failed to process rates...","status":"error"}` |
| 6 |    59 | HTTP 500 \| `{"error":"An unexpected internal error occurred"}` |
| 7 |     1 | HTTP 429 \| `{"error":"Rate limit exceeded (1000/day)"}` |

---

## Response body examples

**Test 1 #1 / Test 2 #1 — ok, rate as Integer**
```json
{"rates": [{"hotel": "FloatingPointResort", "period": "Summer", "room": "SingletonRoom", "rate": 55700}]}
```
Bulk has 36 entries in the same format, each with `"rate": Integer`.

**Test 1 #2 / Test 2 #4 — ok, rate as String**
```json
{"rates": [{"hotel": "FloatingPointResort", "period": "Summer", "room": "SingletonRoom", "rate": "55700"}]}
```
`rate` is a string instead of a number. HTTP status is still 200. Bulk has all 36 entries as strings.

**Test 1 #4 / Test 2 #3 — rate field absent from response**
```json
{"rates": [{"hotel": "FloatingPointResort", "period": "Summer", "room": "SingletonRoom"}]}
```
`rate` key is absent entirely. In bulk, all 36 entries are missing — never just a subset.

**Test 1 #6 / Test 2 #5 — error body**
```json
{"message": "Failed to process rates due to an intermittent issue.", "status": "error"}
```
No `rates` key at all. `status` here is a string in the body, not the HTTP status code (which is 200).

---

## Key findings

**Quota exhaustion signal is HTTP 429 only.**
The real quota signal is HTTP 429 with `{"error":"Rate limit exceeded (1000/day)"}`.
"200 with missing rate field" is an intermittent processing error, not quota exhaustion.

**All error patterns appear in both single and bulk requests.**
Error body and missing rate field patterns confirmed in both test runs.

**When the rate field is missing in bulk, all 36 entries are affected — never just a subset.**
Upstream fails all-or-nothing: either all entries have the rate field, or none do.

**Both modes show similar instability (~7% 500s, ~7% timeouts).**
Processing 36 combinations does not significantly increase error rates compared to single.

**Rate values are sometimes returned as strings.**
`Integer()` handles both `55700` and `"55700"` correctly — no special case needed.

**Quota resets on `docker compose restart rate-api`.**
Confirmed: restarting the rate-api container resets the daily counter to 0.

---

## Special cases — upstream input validation

These were tested directly against the upstream (not via our Rails app).

| # | Scenario | HTTP Status | Body |
|---|---|---|---|
| 1 | No token | 401 | `{"error":"Unauthorized"}` |
| 2 | Invalid token | 401 | `{"error":"Unauthorized"}` |
| 3 | Invalid field value (e.g. unknown period) | 400 | `{"error":"Invalid attribute: {'period': 'InvalidSeason', ...}"}` |
| 4 | Missing field in attribute (e.g. no period) | 400 | `{"error":"Invalid attribute: {'hotel': '...', 'room': '...'}"}` |
| 5 | Request body `{"attributes": []}` — empty array | 200 | `{"rates": []}` |
| 6 | Request body `{}` — `attributes` key missing entirely | 200 | `{"rates": []}` |

Notes:
- 401: empirically verified — upstream does NOT count 401s against its 1000/day quota (1000 invalid-token calls followed by a valid-token call returned 200, not 429). Our QuotaGuard consumes one unit before the HTTP call, but refunds it on 401 since the upstream rejected the request before any processing occurred.
- Empty/missing attributes return HTTP 200 with `{"rates": []}` — no error signal.
  Our code never sends empty attributes (controller validates params first), so this path is unreachable in practice.

---

## Error handling mapping

How `RateApiClient` maps each upstream response to an exception, and what HTTP status the client receives.

| Upstream response | Exception raised | Client status |
|---|---|---|
| HTTP 200, valid rates | — (success) | 200 |
| HTTP 200, rate as String | — (`Integer()` coerces) | 200 |
| HTTP 200, error body (`rates` key absent) | `UpstreamError` | 502 |
| HTTP 200, rate field absent from response | `UpstreamError` | 502 |
| HTTP 200, empty rates array `[]` | `UpstreamError` | 502 |
| HTTP 401 | `UnauthorizedError` (+ quota refunded) | 502 |
| HTTP 429 | `QuotaExhaustedError` | 429 |
| HTTP 500 / other non-200 | `UpstreamError` | 502 |
| Timeout | `TimeoutError` | 504 |
| Our QuotaGuard limit reached | `QuotaGuard::ExhaustedError` | 429 |
