# redis: Kubernetes readiness assessment (Phase 0, NC-3918)

Epic NC-3917. Read-only assessment of `origin/dev` at `7449a76` (working tree on `dev`, same commit).
Repo content: `Dockerfile` (`redis:8.10.3-alpine3.23`, NC-3909), `redis.conf`, `docker-compose.yml`, Trivy workflow.
Also read: `helm/ndb-collection/templates/redis.yaml`, `values.yaml` (redis block), root `docker-compose.yaml` and override.

Settled answer: **one Redis instance, shared by all services**, each service with its own key prefix; the RBAC map
(and the other cross-service keys) in a `shared` store with a common prefix. Redis is used for cache, sessions
(frontend, after Phase 2), locks (`onOneServer`, `Cache::lock`), rate limits, the JWT denylist and, later, queues.

Most of the 11 areas are about Laravel code and do not apply to this repo. The matrix records what Redis must
provide so that the app phases work.

## 1. Matrix

| # | Area | Status | Findings (file:line) | Risk | Phase |
|---|---|---|---|---|---|
| 1 | Stateless / shared state | **Gap** | `maxmemory 1536mb` + **`maxmemory-policy allkeys-lru`** (`redis.conf:20-21`; root compose also `allkeys-lru`, `docker-compose.yaml:96`). Under memory pressure Redis evicts *any* key, including: frontend sessions (users logged out), the `rbac:group_privileges` map (`rememberForever`, gateway then answers 404 to everyone), `revoked_tokens:*` (**a logged-out token becomes valid again**), `refreshed_tokens:*`, scheduler `onOneServer` / `withoutOverlapping` locks (a task can run twice) and, later, queued jobs. All services share one keyspace and one `CACHE_PREFIX`/`REDIS_PREFIX` today (`values.yaml:35-36`). Persistence: AOF `appendfsync everysec` (`redis.conf:14-16`) on a 5 Gi RWO PVC (`values.yaml:289-293`): OK for restarts (≤ 1 s of writes lost). | **H** | 2 (and infra decision) |
| 2 | Communication | N/A (server) | Clients: phpredis with `max_retries 3`, decorrelated-jitter backoff (services' `config/database.php`). No client read/connect timeout configured in the apps (`REDIS_TIMEOUT`/`read_timeout` not set): a hung Redis blocks php-fpm workers. | M | 5 (app side) |
| 3 | Degradation | Gap | Single instance (`templates/redis.yaml:21,29` StatefulSet, 1 replica), no Sentinel. Redis down = login, every gateway request (RBAC map, denylist), frontend sessions and scheduler locks all fail. Expected per settled answer; the apps must fail fast (short timeouts) and readiness of each app must include Redis. PDB: none for Redis (single pod; a node drain takes it down). | H (SPOF, accepted) | 3 / 5 (app side) |
| 4 | Idempotency / concurrency | N/A | Redis provides the locks and idempotency keys for Phase 7; they need a no-eviction guarantee (area 1). | – | 7 |
| 5 | Security | Gap | `protected-mode no`, `bind 0.0.0.0` (`redis.conf:4-5`). Password only when `REDIS_PASSWORD` is set (`Dockerfile:26`); the chart secret key is optional and empty by default (`values.yaml:51`, `templates/redis.yaml:54-55`); the repo compose starts without it (`docker-compose.yml:17`, "NO password"). No TLS. No ACL users per service (any service can read/flush every other service's keys and the shared RBAC/denylist keys). No `rename-command` for `FLUSHALL`/`FLUSHDB`/`CONFIG`/`KEYS`. NetworkPolicy lets any app pod reach Redis but is off by default (`values.yaml:321-322`). | M | 6 |
| 6 | Config | Partial | Config baked into the image (`Dockerfile` `COPY redis.conf`); `maxmemory 1536mb` vs pod limit 2 Gi (`values.yaml:288`): OK, but `maxmemory` is not configurable per environment. `databases 16`: separate DB numbers for cache/session/queue are possible (`REDIS_DB`, `REDIS_CACHE_DB`). Base image pinned (NC-3909): OK. | L | 1 |
| 7 | Health / lifecycle | OK | Docker `HEALTHCHECK` and Helm readiness/liveness run `redis-cli ping` with the password when set (`Dockerfile:23-24`, `templates/redis.yaml:56-63`). `exec redis-server` so SIGTERM reaches Redis and it shuts down cleanly (AOF flush). Runs as non-root (`USER redis`, pod `runAsUser 999`). | L | – |
| 8 | Jobs / schedule | N/A | No queues on Redis yet (`QUEUE_CONNECTION: sync` everywhere, `values.yaml:33`); the local override sets `redis` without a worker. Locks for schedulers are on Redis (NC-3886): see area 1 for eviction. | M | 8 |
| 9 | Logging | OK | `loglevel notice` to stdout (no `logfile`): container logs. No slowlog/latency settings tuned (defaults). | L | 4 |
| 10 | Database (capacity) | Gap | No sizing data: sessions (frontend stores user, menus, notification list per session), cache of every service, rate limit counters. `maxmemory` 1.5 GB with LRU hides growth instead of alerting. No `INFO`/metrics exporter. | M | 7 (capacity) |
| 11 | Contracts | Gap | Cross-service key contracts are only in code comments: `rbac:group_privileges` (auth writes, gateway + services read), `revoked_tokens:<jti or sha256>` and `refreshed_tokens:*` (auth writes, gateway reads), frontend `groupPrivilegeCodes`. Prefix plan not written down. | M | 2 / 9 |

### Earlier work verified
- NC-3886 (Redis cache and scheduler locks): the stores point at Redis in Helm/compose. The guarantee that the locks
  survive is missing because of `allkeys-lru`.
- NC-3909: base image pinned and `apk upgrade` at build.
- Helm probes: real (`redis-cli ping`). No PDB for Redis (by design, one replica). NetworkPolicy: Redis reachable by all release pods when enabled.

## 2. User operations served

None directly. Every user operation depends on Redis through the apps:

| Dependency | Used by | Effect when Redis is down or the key is evicted |
|---|---|---|
| Frontend sessions (after Phase 2) | every screen | user sent to login |
| `rbac:group_privileges` (shared) | gateway `check.permission`, services' `checkRBAC()` | 404 "permission cache not found" for every API call until the next login rebuilds it |
| `revoked_tokens:*` (shared) | gateway `ValidateJwt`, auth | down: requests fail; evicted: revoked token accepted again |
| `refreshed_tokens:*` | auth refresh | reuse-window check lost |
| Rate limits (wallboard, later login/API) | gateway | down: requests fail (fail open/closed decision, matrix row 14) |
| Scheduler locks (`onOneServer`, `withoutOverlapping`) | customer, dashboard, report, communication, agency, workflow schedulers | evicted: a task can run twice |
| Queues (Phase 8) | services with jobs | evicted: jobs lost |

## 3. Change list per phase

**Phase 1 (config)**
- Make `maxmemory` and the policy configurable (env or a ConfigMap-mounted `redis.conf` in Helm) instead of baked in.

**Phase 2 (shared state)** - main item
- Eviction policy. Options: (a) `noeviction` (writes fail when full: visible, nothing silently lost; needs monitoring and enough memory); (b) `volatile-lru` (only keys with a TTL are evicted; but sessions, denylist entries, locks and cache entries all have TTLs, so this protects only `rememberForever` keys such as the RBAC map); (c) two instances: one for cache (LRU) and one for state (sessions, locks, denylist, queues; `noeviction`). **Decision (infra/team):** a/b/c. The settled answer says one instance, so (a) with alerts is the closest fit.
- Prefix plan (write it down here and in each repo's `.env.example`): `ndb_<service>_` for each service's `CACHE_PREFIX`/`REDIS_PREFIX`, and a `shared` cache store with a common prefix for `rbac:group_privileges`, `revoked_tokens:*`, `refreshed_tokens:*`. Separate DB numbers: e.g. 0 = default/locks, 1 = cache, 2 = sessions, 3 = queues.

**Phase 3 (health)**: nothing in this repo; every app's readiness pings Redis.

**Phase 5 (communication)**: app side, add `REDIS_TIMEOUT`/`REDIS_READ_TIMEOUT` (e.g. 1-2 s) to every service's `config/database.php` redis connections so a hung Redis fails fast.

**Phase 6 (security)**
- Make `REDIS_PASSWORD` required in the chart (not `optional: true`) outside local; set `protected-mode yes` when a password is set.
- Optional: ACL users (one per service, key patterns `~ndb_<service>_*` plus read on the shared keys; auth write on shared keys). **Decision:** per-service ACLs need one Redis secret per service (chart change).
- `rename-command FLUSHALL ""`, `FLUSHDB ""`, `KEYS ""` (or ACL `-@dangerous`). Check first that no app uses `Cache::flush()` / `KEYS` (a quick grep before the change).
- TLS only if the platform requires it (phpredis supports `tls://`). **Decision:** infra.
- NetworkPolicy: allow Redis ingress only from release app pods (already the case when enabled); enable by default.

**Phase 7 (capacity)**: estimate memory (sessions × size + cache), set `maxmemory` with headroom, add a Redis exporter or `INFO memory` alert when the platform has metrics.

**Phase 8 (jobs)**: when queues move to Redis, use a separate DB number and make sure the eviction policy cannot drop them (Phase 2 decision).

**Phase 9 (contracts)**: document the cross-service keys (name, writer, readers, format, TTL) in this repo's README.
