# Phase 5: Service communication and graceful degradation (Guidelines 2, 3)

Main repos: **api-gateway** (all proxy traffic), **frontend** (server-side calls), and any service with explicit HTTP calls to another.

## 5.1 Timeouts (every outbound call)
- `connectTimeout`: 2s (inside the cluster, a connect that takes longer means the target is down).
- Request `timeout`: per target from config. Default 10s. Reports/exports have their own value or are made async.
- **End-to-end budget:** browser/frontend ≥ gateway ≥ service. Example: frontend 20s > gateway 15s > service-side Oracle
  query timeout 12s. The inner layer always gives up first, so the outer layer gets a real error instead of waiting.
- php-fpm `request_terminate_timeout` and nginx `fastcgi_read_timeout` sit slightly above the gateway timeout.
```php
Http::connectTimeout(config('gateway.connect_timeout'))
    ->timeout(config("gateway.timeouts.$service", config('gateway.timeout')))
    ->withHeaders(['X-Request-ID' => $rid, 'Authorization' => $auth])
    ->send($method, $url, $options);
```

## 5.2 Retries (careful: retries can overload a struggling service)
- Retry **only** idempotent requests (`GET`, `HEAD`, or a write that carries an `Idempotency-Key`, see Phase 7).
- Retry **only** on connection errors and `502/503/504`. Never on `4xx` or `500`, and never on a timeout of a write.
- Max 2 retries, exponential backoff with jitter (e.g. 100ms, 300ms ± random).
- Retries must fit inside the end-to-end budget.
- Retry at **one layer only**: the gateway. The frontend doesn't retry gateway calls, and services don't retry each other blindly.

## 5.3 Circuit breaker (minimal, Redis-based, no package)
Per target service, in a small `CircuitBreaker` class:
- Count failures (connection error, timeout, 5xx) in Redis over a 30s window.
- ≥ N failures (e.g. 10) → **open** for 30s: return `503` immediately with code `SERVICE_UNAVAILABLE`, without calling the service.
- After the cooldown → **half-open**: let one request through. Success closes the circuit. Failure opens it again.
- Log state changes (warning level).

## 5.4 Bulkhead
In PHP-FPM each request uses one worker, so one slow service can use up all gateway workers.
- The main defence is short per-service timeouts plus the circuit breaker.
- Optional: limit concurrent in-flight calls per target with a Redis counter (`INCR`/`DECR`, TTL safety). Over the limit → `503` fast.
- Size gateway `pm.max_children` and replicas for the peak, not the average.

## 5.5 Standard error responses (all services + gateway)
One envelope, kept compatible with what the frontend reads today (confirm the current shape first):
```json
{ "success": false, "error": { "code": "CUSTOMER_NOT_FOUND", "message": "Customer not found", "type": "business" },
  "request_id": "..." }
```
| Situation | Status | `type` |
|---|---|---|
| Validation | 422 | business |
| Business rule (e.g. PTP date in past) | 409 / 422 | business |
| Not authenticated / not permitted | 401 / 403 | security |
| Downstream unreachable / circuit open | 503 | technical |
| Downstream timeout | 504 | technical |
| Unexpected | 500 (no stack trace) | technical |

- The gateway **passes service business errors through unchanged** and creates `503/504` itself for technical failures.
- The frontend shows business messages as they are. Technical errors get a generic "temporarily unavailable, try again" with the `request_id`.

## 5.6 Graceful degradation
- Classify each dependency of each screen as **critical** or **optional** (fill `11-operation-behaviour-matrix.md`).
- Where the frontend or gateway builds one page from several services (e.g. customer 360 plus dashboard widgets), call them
  in parallel (`Http::pool`) and return the parts that worked, plus `"meta": {"partial": true, "unavailable": ["report-service"]}`.
  The frontend shows a "section unavailable" placeholder.
- Critical dependency down (e.g. auth for login, customer for the customer screen) → fail fast with 503, don't wait.
- Optional cached reads (reference data lists) may serve a **stale cache** copy when the service is down. Use a short TTL plus a stale fallback.

## 5.7 Sync vs async
Make it async (queue + `202`) when the caller doesn't need the result to continue: SMS/email/letters, report generation,
bulk allocation, notifications. Keep sync for screen reads and single-record saves.

## Tests
Feature tests with `Http::fake()` covering: timeout → 504, connection refused → 503, circuit opens after N failures,
no retry on POST, business 422 passed through unchanged.

> **STOP.** Show the per-service timeout table, the breaker settings, and the test results.
