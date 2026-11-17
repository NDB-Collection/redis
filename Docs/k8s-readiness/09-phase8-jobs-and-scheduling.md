# Phase 8: Background jobs and scheduled tasks (Guideline 8)

**Target:** with N web replicas and M workers, each scheduled task runs **once**, each job is safe to retry, and a killed
worker never leaves a half-done job.

## Process layout per service (one image, different commands)
| Deployment | Command | Replicas |
|---|---|---|
| `<svc>-web` | nginx + php-fpm | 2+ (HPA) |
| `<svc>-worker` (only if the service has jobs) | `php artisan queue:work redis --queue=<svc>-high,<svc>-default --sleep=1 --tries=3 --timeout=120 --max-time=3600` | 1+ |
| `<svc>-scheduler` (only if the service has a schedule) | `php artisan schedule:work` | **exactly 1** |

The web pods never run the scheduler. Remove any OS cron from the images.

## Steps
1. **Queue driver:** `QUEUE_CONNECTION=redis`, never `sync` in UAT/PROD. Per-service queue names (`customer-default`, …).
2. **Timeouts in the right order:** job `$timeout` < worker `--timeout` < `retry_after` (in `config/queue.php`) < pod
   `terminationGracePeriodSeconds`. Example: 120 < 120 < 180 < 200. If `retry_after` is shorter than the job, the job runs twice.
3. **Every job sets** `$tries`, `$backoff` (e.g. `[30, 120, 300]`), `$timeout`, and `failed()` (log + alert). Use `$maxExceptions` where useful.
4. **Idempotent jobs:** a job may run more than once (retry, or a worker killed after the work but before the ack). Make it safe:
   - check-then-act on a status column (`SENT_AT is null`) inside a transaction with `lockForUpdate`, or
   - `ShouldBeUnique` / the `WithoutOverlapping` job middleware keyed by the business id, or
   - an idempotency key stored with the result (Phase 7).
   SMS/letters: mark "sending" → send → mark "sent" with the provider reference, and skip it if already sent.
5. **Scheduled tasks:** every entry gets `->onOneServer()->withoutOverlapping(<minutes>)`, needs a Redis cache store,
   and a `->name()` for closures. This stays in place even with 1 scheduler replica, because it covers rollout overlap when two scheduler pods briefly co-exist.
   Long tasks: `->runInBackground()` or better, the task dispatches a job and returns.
6. **Graceful worker shutdown:** `queue:work` finishes the current job on `SIGTERM`. Ensure the grace period covers the longest job.
   On deploy, the new pods start and the old ones drain (no `queue:restart` needed in K8s, though it's harmless).
   Use `--max-time`/`--max-jobs` to recycle workers and avoid memory leaks.
7. **Failed jobs (dead-letter):** `failed_jobs` table in the shared schema. Either use one table with the queue name
   showing the owner (simplest), or per-service tables via `QUEUE_FAILED_TABLE`. Decide once. Runbook: `queue:failed`, `queue:retry <id>`, `queue:forget`.
   Add a daily scheduled report or alert when failed jobs > 0.
8. **Monitoring:** log queue wait time (dispatch → start) and run time per job. Horizon is optional. If it's used: one Horizon
   per service, dashboard protected by auth, and it replaces `queue:work` in the worker deployment.
9. **EOD / batch triggers:** if the schedule triggers Oracle EOD procedures, guard them with a DB-level or Redis lock **and** a
   "run date already processed" check so a rerun or a duplicate pod can't process the same business date twice.

## Tests
- Run a scheduled command twice in parallel: only one does the work.
- Dispatch the same job twice for the same business id: the side effect happens once.
- Kill a worker mid-job (`docker kill -s TERM`): the job completes or is retried safely.

> **STOP.** Show the job table (name, queue, tries, timeout, idempotency method) and the schedule table (task, frequency, lock).
