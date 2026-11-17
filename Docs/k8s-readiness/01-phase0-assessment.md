# Phase 0: Assessment (read-only)

Output: `Docs/k8s-readiness/<repo>-assessment.md`. **No code changes.**

## Steps
1. Read `CLAUDE.md`, `.claude/skills`, `composer.json`, `config/*.php`, `.env.example`, `routes/*`,
   `app/Console`, `app/Jobs`, `app/Http/Middleware`, `Dockerfile`/`docker-compose*` if present.
2. Run each grep below and record the hits (file:line) in the assessment.

| # | Area | What to look for | Commands / hints |
|---|---|---|---|
| 1 | Stateless | file/array session or cache drivers, `storage_path()`/`Storage::disk('local')` writes, static props or singletons holding request data, `$_SESSION`, local file locks | `grep -rn "SESSION_DRIVER\|CACHE_DRIVER\|CACHE_STORE" .env.example config/`<br>`grep -rn "storage_path(\|Storage::disk('local')\|file_put_contents\|fopen(" app` |
| 2 | Communication | `Http::` / Guzzle calls without `timeout()`/`connectTimeout()`, `retry()` on POST, missing error handling | `grep -rn "Http::\|new Client(" app` |
| 3 | Degradation | screens/endpoints that call several services, try/catch returning 200 on failure, mixed error formats | `grep -rn "catch (" app` |
| 4 | Idempotency / concurrency | POST/PUT endpoints that create money/PTP/allocation/SMS/letters; read-modify-write without a lock; `DB::beginTransaction` without commit/rollback in `finally` | `grep -rn "DB::transaction\|beginTransaction\|lockForUpdate\|sharedLock" app` |
| 5 | Security | routes outside the `jwt` group, scope checks only in gateway, `env()` secrets in code, sensitive fields in responses (NIC, account no, phone) | `grep -rn "env(" app routes` |
| 6 | Config | `env()` outside `config/`, hard-coded hosts/IPs/URLs, `APP_DEBUG=true`, keys in repo | `grep -rnE "https?://\|[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}" app config` |
| 7 | Health / lifecycle | existing health route, work done at boot (DB calls in service providers), long requests | `grep -rn "health\|/up" routes bootstrap` |
| 8 | Jobs / schedule | scheduled tasks without `onOneServer()`/`withoutOverlapping()`, jobs without `$timeout`/`$tries`, `QUEUE_CONNECTION=sync`, failed-job table | `php artisan schedule:list`<br>`grep -rn "ShouldQueue\|->daily\|->everyMinute\|->cron(" app routes` |
| 9 | Logging | log channel (file vs stderr), request id, PII in logs | `grep -rn "Log::" app \| head -100` |
| 10 | Database | N+1 (loops with relation access), `->get()` without limits on big tables, long transactions, raw SQL concatenation | `grep -rn "DB::select(\|DB::statement(" app` |
| 11 | Contracts | OpenAPI/Swagger present? response wrappers consistent? route versioning? | `ls docs openapi* storage/api-docs 2>/dev/null` |

3. Fill the matrix:

| Area | Status (OK / Gap / N/A) | Findings (file:line) | Risk (H/M/L) | Phase that fixes it |
|---|---|---|---|---|

4. List the **user operations** this repo serves (for `11-operation-behaviour-matrix.md`): name, route,
   services and tables touched, is it a write?

> **STOP.** Show the matrix and the top 10 risks. Wait for approval before Phase 1.
