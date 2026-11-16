# Operation behaviour matrix

The guideline asks: *"We should be able to explain how each major user operation behaves when one of its
dependencies is unavailable."* Claude Code fills this from Phase 0 (operations) and Phases 5–8 (behaviour).
The rows below are **starting assumptions** to confirm or correct.

| # | Operation | Path (via gateway) | Dependencies | Critical / optional | If a dependency is down | Write? Idempotency | Timeout |
|---|---|---|---|---|---|---|---|
| 1 | Login | frontend → gateway (public) → auth | auth, Oracle, Redis (session) | all critical | 503, "login temporarily unavailable". No retry of POST. | yes (session), rate-limited | 5s |
| 2 | Token refresh | gateway → auth | auth, Oracle | critical | 401 → back to login | – | 5s |
| 3 | Customer 360 / account view | gateway → customer | customer (critical), reference-data (labels, optional), workflow/legal status (optional) | mixed | Customer down → 503. Optional parts → section shows "unavailable" | read | 10s |
| 4 | Save follow-up / PTP | gateway → customer (or campaign) | owning service, Oracle | critical | 503, form keeps input, user retries with the **same Idempotency-Key** | yes, key + natural unique rule | 10s |
| 5 | Collector work queue / allocation list | gateway → campaign | campaign, Oracle | critical | 503 | read | 10s |
| 6 | Allocation run / reallocation | scheduler/job in campaign | Oracle, Redis lock | critical | job retries with backoff; lock prevents double run | yes, lock + run-date check | job 300s |
| 7 | Dashboard | gateway → dashboard | dashboard, Oracle | widgets optional | widget-level "unavailable", the rest still loads (`meta.partial`) | read | 10s |
| 8 | Report export | gateway → report (async) | report, Oracle, shared storage | critical for that report | `202` + status. Job retries. Download from shared storage | job idempotent per request id | job 600s |
| 9 | SMS / email / letter | job in communication | provider gateway, Oracle | optional for the triggering action | the action saves anyway. Message job retries, then `failed()` alert | yes, skip if `SENT_AT` set | provider 10s |
| 10 | Workflow approve / reject | gateway → workflow | workflow, Oracle | critical | 503. Optimistic lock → 409 if already actioned | yes, version check + key | 10s |
| 11 | Disposal step update | gateway → disposal | disposal, Oracle | critical | 503. 409 on concurrent change | yes | 10s |
| 12 | Agency assignment | gateway → agency | agency, Oracle | critical | 503 | yes, key | 10s |
| 13 | Reference data lists (dropdowns) | gateway → reference-data | reference-data, Redis cache | optional | serve stale cache, else empty list + message | read | 5s |
| 14 | Any request | gateway | Redis (rate-limit, breaker) | degrade | if Redis is down: fail open for the breaker, fail closed for login rate limit (decide) | – | – |

**Rules shown in this matrix**
- The gateway is never restarted because a service is down (readiness checks only its own dependencies).
- Business errors pass through unchanged. Technical failures become 503/504 with `request_id`.
- Writes are never retried without an Idempotency-Key.
