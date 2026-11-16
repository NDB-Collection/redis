# Phase 4: Logging, correlation IDs, metrics (Guideline 9)

**Target:** one ID lets you follow a user action through frontend → gateway → service → Oracle.

## Steps
1. **Log to stderr as JSON.** In `config/logging.php`, a `stderr` channel with `Monolog\Formatter\JsonFormatter`;
   `LOG_CHANNEL=stderr`, `LOG_LEVEL=info` in UAT/PROD. No log files inside the pod.
2. **Request ID middleware** (global, first in the stack) in every repo:
   - Read `X-Request-ID`. If it's missing (only the frontend/gateway edge should ever see it missing), generate a UUID.
   - Put it in the log context: `Log::withContext(['request_id' => $id, 'service' => config('app.name')])`
     (Laravel 11+: `Context::add(...)`, which also flows into queued jobs).
   - Return it in the response header `X-Request-ID`.
3. **Propagate it:**
   - frontend → gateway: add the header to every server-side `Http::` call, and send it in AJAX through a global header in the JS HTTP client.
   - gateway → service: forward `X-Request-ID` (plus `traceparent` if present) when proxying.
   - service → service (explicit calls) and queued jobs: carry the ID (job property or `Context`).
4. **Standard log fields:** `request_id`, `service`, `user_id` (from JWT `sub`), `route`, `method`, `status`,
   `duration_ms`. Add one "request finished" log line per request from a terminable middleware.
5. **No sensitive data in logs:** never log JWTs, passwords, `Authorization` headers, full NIC/account/card numbers, or request bodies of
   login/payment endpoints. Add a small masking helper and use it in the request logger.
6. **Gateway dependency logs:** for every proxied call log `target_service`, `upstream_status`, `upstream_ms`, `timeout`/`connection_error`.
   This becomes the per-dependency error rate and latency.
7. **Metrics (minimal):** start with log-based metrics (count/latency from the JSON lines). Only add Prometheus or OpenTelemetry
   when the platform team provides a collector. Leave a hook in the request-finished middleware.
8. **Tracing (later, optional):** OpenTelemetry PHP auto-instrumentation using W3C `traceparent`. Treat it as a separate ticket.
   The request ID above covers the immediate need.

## Verify
One login plus one customer screen produces the same `request_id` in frontend, gateway and customer-service logs.

> **STOP.** Show a sample of the three correlated log lines.
