# Phase 7: Idempotency, concurrency, consistency, DB connections (Guidelines 4, 10)

**No Saga for NDB.** Each write operation commits in one Oracle transaction inside one service. Anything that has to happen
after the commit (SMS, letters, notifications, calls to other services) is a queued job dispatched *after commit*.

## 7.1 Find the critical writes
From Phase 0, list every write endpoint and job. Mark the ones where a duplicate or a half-done result matters. Likely NDB examples:
PTP / follow-up action save, payment-related updates, campaign allocation/reallocation run, SMS/letter send,
workflow approve/reject, disposal step update, agency assignment, user/password changes. Confirm the list with the team.

## 7.2 Idempotency keys (critical POST/PATCH)
- The client (frontend) generates `Idempotency-Key: <uuid>` once per user action (form submit) and reuses it on retry.
- Middleware `idempotent` in the service:
  1. key = `idem:{service}:{user}:{Idempotency-Key}`
  2. `Cache::lock(key.':lock', 30)`. If the lock is busy → `409 REQUEST_IN_PROGRESS`.
  3. If a stored response exists → return it (same status/body). Don't run the operation again.
  4. Otherwise run it and store `{status, body, request_hash}` for 24h in Redis.
  5. Same key with a different body hash → `422 IDEMPOTENCY_KEY_REUSED`.
- For the most critical writes, also add a **natural uniqueness rule** in Oracle (e.g. unique on account + PTP date + amount + source ref).
  This is a schema change, so ask and route it through the owning service's migration.
- Only the gateway retries, and only writes that carry a key (Phase 5).

## 7.3 Concurrency
- **Optimistic locking** for user edits of the same record (two collectors, a supervisor and a collector): add a `VERSION_NO` column
  if one exists or is approved, or compare `UPDATED_AT`. Update with `WHERE id = ? AND version_no = ?`; 0 rows → `409 RECORD_CHANGED`.
- **Pessimistic locking** for short critical sections over shared rows (allocation, counters, sequence-like numbering):
  `DB::transaction(fn () => Model::whereKey($ids)->lockForUpdate()->get() ...)`. Keep it short, lock rows in a consistent
  order (by id) to avoid deadlocks, and set `attempts` on `DB::transaction(..., 3)` to retry deadlocks (ORA-00060).
- **Distributed locks** (Redis `Cache::lock`) for jobs/runs that must not run twice in parallel (allocation per campaign, EOD-triggered tasks).

## 7.4 Transactions
- Every multi-statement write goes in `DB::transaction()`. No `beginTransaction` without `rollBack` in a `catch`/`finally`.
- No HTTP calls or queue waits **inside** a transaction (they hold locks while waiting on the network).
- Dispatch follow-up jobs after commit: `config/queue.php` → `'after_commit' => true`, or `->afterCommit()` per job.
- Isolation: the Oracle default (READ COMMITTED) is fine. Use `lockForUpdate` where a read-then-write must be safe.

## 7.5 Outbox (only where needed)
Most NDB cases are covered by `afterCommit` jobs. A full transactional outbox (a `TBL_OUTBOX` row written in the same
transaction plus a relay job) is needed only if losing a Redis job after commit is unacceptable (e.g. a regulatory letter or a payment notification).
Ask before adding it, because it's a schema change.

## 7.6 Database connections and performance (Guideline 10)
- **Count connections:** total = Σ (replicas × php-fpm `pm.max_children` + queue workers) over all services. Compare with the
  Oracle app-user / `processes` limit. Set `pm.max_children` and HPA max replicas so the total stays under the limit with headroom.
- Prefer **Oracle DRCP** (pooled server) if the DBA enables it. Otherwise keep non-persistent connections and right-size the pools.
- Set a per-query timeout where long queries are possible (report/dashboard). Make heavy reports async (Phase 5.7).
- **N+1:** enable `Model::preventLazyLoading(! app()->isProduction())` in AppServiceProvider and fix the violations with `with()`.
- No unbounded `->get()` on big tables. Paginate or `chunkById()`. Batch `IN` lists over 1000 items (Oracle limit).
- Cache only slow-changing reads (reference data) in Redis with a TTL, and clear them on update in the owning service.
- **Backward-compatible migrations (expand → migrate → contract):** add nullable columns or new tables first, deploy the code that
  works with both, backfill, and only drop or rename in a later release. Never rename a column used by a running version.
  This matters because the schema is **shared** by all services.

> **STOP.** Show the critical-write list with the protection applied to each, and the connection budget table.
