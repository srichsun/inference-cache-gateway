# Inference Cache Gateway

> A Case Study in Caching & Quota Design — by **Dane Wu**

---

## The Problem

An AI-driven pricing model is **computationally expensive** to run.
The upstream rate API caps daily calls at **1,000 / day per token**, but the
consumer-facing service must handle **1,000,000+ requests / day** — a
**1,000:1 demand-to-supply ratio**.

Caching alone isn't enough. There are 36 parameter combinations
(period × hotel × room), each with a 5-minute TTL, so the worst case is
**36 × 288 = 10,368 cache misses / day** — already 10× over budget.

**The question:** how do you stretch 1,000 expensive calls into 1M+ requests
without sacrificing freshness, correctness, or the upstream contract?

---

## My Solution

Four protective layers on top of a Rails 7.1 API proxy:

1. **Lazy fallback + Bulk fetch** — one upstream call returns all 36 rates,
   triggered only on cache miss. Achieves the **math floor of 0 ~ 288 calls / day**
   (24h ÷ 5-min TTL).
2. **Single-flight Redis lock** (SETNX + fencing-token UUID) — collapses
   bursts of concurrent cache misses into a single upstream call.
3. **QuotaGuard** — atomic Redis INCR enforces a **1,000 / day hard ceiling**,
   holding even if the layers above break or upstream's own rate limiter
   misconfigures.
4. **Anti-Corruption Layer** — typed exceptions + dry-schema validation absorb
   upstream's ~28% flakiness (200 with bad body / missing field / 5xx /
   timeout); the service only sees clean data or well-defined errors.

### Verified results

| Metric | Value |
|---|---|
| API calls / day | **0 ~ 288** (budget 1,000) — math floor under 5-min TTL |
| Single-flight ratio | **663 : 1** (1,327 requests → 2 upstream calls under cold-cache burst) |
| Cache hit rate | **99.94%** sustained at 230 req / sec |
| Load & Chaos Tests | **4 / 4 passing** — single-flight · cache hit · quota cap · fail-closed |
| Unit test coverage | **100%** (202 / 202 lines) |

---

## Full Documentation

Architecture diagrams, decision trees, failure-mode analysis, trade-off
discussion, and interactive demos — all in one page:

### **[Open Design Document →](https://inference-cache-gateway.netlify.app/)**
