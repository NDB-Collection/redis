# NDB – Kubernetes Readiness: Step-by-step Transformation (for Claude Code)

## Goal
Make the NDB Laravel apps behave correctly when they run as **multiple replicas that can be restarted,
replaced or rescheduled at any time**. This pack covers the application changes only. Cluster administration
is out of scope.

## How the guideline maps onto NDB
| Guideline term | NDB component |
|---|---|
| BFF | `api-gateway` (:8000). It's a pass-through `/api/{service}/{path}` proxy with JWT + scope checks. `frontend` (:8100) also makes server-side calls. |
| Microservices | auth (:8200), reference-data (:8201), dashboard (:8202), report (:8203), campaign (:8204), communication (:8205), agency (:8206), customer (:8207), workflow (:8209), disposal (:8210) |
| Shared cache / sessions / queues | Redis (`my-redis`) |
| Database | One shared Oracle schema (`TBL_*`, one `migrations` table) via `yajra/laravel-oci8` |
| Saga / distributed transactions | **Not used for NDB** (agreed). Each service's write stays in one Oracle transaction. |

## Files
| File | Guideline areas | Repos |
|---|---|---|
| `01-phase0-assessment.md` | all 11 | all |
| `02-phase1-config-and-secrets.md` | 6 | all |
| `03-phase2-stateless-and-shared-state.md` | 1 | all (frontend first) |
| `04-phase3-health-and-lifecycle.md` | 7 | all |
| `05-phase4-logging-and-tracing.md` | 9 | all (gateway first) |
| `06-phase5-service-communication.md` | 2, 3 | gateway, frontend, any service that calls another |
| `07-phase6-security.md` | 5 | gateway + all services |
| `08-phase7-data-integrity.md` | 4, 10 | services that write |
| `09-phase8-jobs-and-scheduling.md` | 8 | services with jobs / schedule |
| `10-phase9-api-contracts.md` | 11 | all |
| `11-operation-behaviour-matrix.md` | 3 | output: how each user operation behaves when a dependency fails |
| `12-final-readiness-checklist.md` | all | sign-off per repo |

## Order and why
1. **Phase 0** assessment: find out where each repo stands.
2. **Phases 1–4** (config, stateless, health, logging) are the foundation. Without them a pod can't
   even run safely as two replicas, and you can't debug anything.
3. **Phases 5–6** (communication, security) build the protection at the gateway and service boundary.
4. **Phases 7–8** (data integrity, jobs) cover anything that writes or runs in the background.
5. **Phase 9** (contracts) makes independent deployments safe.

Do the **foundation phases repo by repo** in this order: `frontend` → `api-gateway` → `auth-service` →
the other services. After that, go **phase by phase** across repos.

If a service hasn't had its domain clean-up yet (`Docs/service-cleanup/`), do that first. Don't harden code that is about to be deleted.

## Ground rules for Claude Code
- Read the repo's `CLAUDE.md` and `.claude/skills` first. They override this pack where they conflict.
- One branch per repo per phase: `feat/k8s-<phase>-<repo>`. Small commits. Never push or merge.
- **No API contract change** unless the phase file says so (and then additive only).
- **No Oracle schema change** without asking. Shared schema, shared `migrations` table: migrations only
  with `--path`, one file, from the owning service. Never fresh/rollback/reset/wipe.
- Prefer Laravel built-ins over new packages. Ask before adding any package.
- Every phase ends with **STOP**: show the diff summary, test results and open questions.

## Prompt to paste into Claude Code (per repo, per phase)
```
We are preparing <REPO> (NDB SmartCollect) to run as multiple replicas in Kubernetes.
1. Read CLAUDE.md and .claude/skills first. Tell me which skills you'll use.
2. Read Docs/k8s-readiness/00-README.md and then Docs/k8s-readiness/<PHASE FILE>.
3. Do only that phase for this repo, on branch feat/k8s-<phase>-<repo>. Never push or merge.
4. Ask me before: adding a package, changing an API response, or anything touching the Oracle schema.
5. Stop at the STOP marker and report.
```

## Questions to settle once, before Phase 1 (record the answers in this file)
1. Secrets source in the cluster: plain K8s Secrets, Sealed Secrets, or Vault?
2. Shared persistent storage for generated files (reports, letters, uploads): RWX volume (NFS) or S3-compatible object storage (e.g. MinIO)?
3. Redis in the cluster: single instance or Sentinel/cluster? Is it shared by all services (then a key prefix per service is mandatory)?
4. Laravel version per repo (affects `/up` health route, `Context` facade, `bootstrap/app.php` vs `Kernel.php`).
5. Web runtime image: nginx + php-fpm in one pod (two containers), or a single image?
6. Oracle: is DRCP (Database Resident Connection Pooling) available on the NDB DB? What is the connection limit for the app user?
7. Are services reachable only from inside the cluster (NetworkPolicy), with only the gateway and frontend exposed through ingress?

## Answers (settled 2026-11-16)
1. **Secrets:** the chart only references an existing K8s Secret (`secrets.existingSecret`), one per environment, created by the admins by hand, with Sealed Secrets or with External Secrets. No secrets in values files.
2. **Shared storage:** ReadWriteMany PVCs (NFS), already in the chart since NC-3889 (`privateStorage.*`, `publicStorage.existingClaim`).
3. **Redis:** a single instance for now, shared by all services.
   - Each service gets its own key prefix for sessions, cache, locks and queues.
   - The RBAC map `rbac:group_privileges` (written by auth, read by every service, NC-3886) moves to a separate `shared` cache store with the common prefix.
4. **Laravel:** 13 in every repo (PHP 8.5). `bootstrap/app.php`, `/up` and `Context` are available.
5. **Runtime image:** keep the current single image per service (nginx + php-fpm in one container, as the Dockerfiles build today).
6. **Oracle:** DRCP availability and the app user's connection limit are unknown, so plan without DRCP:
   - cap PHP-FPM workers per pod through env (`pm.max_children`);
   - document the budget formula, services × replicas × workers ≤ limit;
   - keep DRCP as an option for the DBA.
7. **Network:** only the gateway and frontend are exposed through ingress. The backends are reachable only inside the cluster (`networkpolicy.yaml`).

Scope: all phases. Each phase gets one branch per repo and one PR per repo against `dev`, and nothing is merged. Work stops only for real decisions: adding a package, an API response change, or an Oracle schema change. Workspace and repo CLAUDE.md rules win where they conflict with this pack (branch `feature/NC-<n>-k8s-<phase>`, commit format `[NC-<n>]`).

## Decisions after Phase 0 (2026-11-16)
User decisions:
1. **Redis eviction:** `maxmemory-policy noeviction`, with a maxmemory alert. Every cache entry gets a TTL. It stays a single instance.
2. **Error responses:** fix the wrong codes and keep validation at 400.
   - Failures stop answering 200.
   - The gateway answers 503 when a service is down and 504 when it is slow.
   - Duplicate actions answer 409.
   - `request_id` and `type` are added to every error body.
3. **Oracle schema:** constraints and columns that prevent duplicates are allowed. Each one is its own migration that first checks the existing data. If duplicates exist, it stops and reports them; it never deletes data. Each runs once on the test DB, with a backup where rows change.
4. **Long work:** a Redis queue plus a worker deployment (same image, worker role). Long exports and bulk operations return `202` with a status URL; the frontend polls and then downloads.
5. **Idempotency:** the frontend sends an `Idempotency-Key` header on critical writes. A service middleware keeps the response in Redis for 24h and replays it on a repeat. The services also re-check the status under a row lock and answer 409 when the record is already actioned.
6. **Tracked env files:** `.env_dev` (gateway, frontend), `.env.testing` (auth) and the frontend `access.log`/`error.log` are untracked (`git rm --cached` plus `.gitignore`), with credentials-free examples. History is not rewritten; the user rotates the keys.
7. **Gateway audit:** stays synchronous on Oracle. `pm.max_children` comes from env per service, the gateway default is lower, and the connection budget is documented.
8. **PII:** remove the pod-local log files and mask NIC, phone and account numbers in every log line. API responses and URLs stay as they are; the NIC-in-URL routes become follow-up tickets.

Calls Claude made itself (routine, reversible):
- **RBAC map:** rebuilt automatically when missing (rebuild on read through auth's action, under a Redis lock) and refreshed by a scheduled task in auth. A missing map no longer blocks everyone.
- **Frontend permission cache:** stays the frontend's own `groupPrivilegeCodes` format, but in Redis with a TTL.
- **Access-token TTL:** unchanged (60 min). Helm's `JWT_EXPIRATION` is aligned to the `JWT_TTL` key the code reads.
- **Request id:** the gateway accepts a valid incoming `X-Request-ID` (UUID). The frontend sends one id per page request across its gateway calls.
- **`audit:trace`:** its log-file search is kept as an optional path. It reads the audit tables, which keep working.
- **ISVA SSO and dialer leftovers in the frontend:** remove the env keys and dead code (already decided in NC-3861) only where a phase touches them.
- **State-changing GETs** (campaign `campaign-account/{id}`, `campaign-account/search/{id}`): never retried. A POST alias is a follow-up.
