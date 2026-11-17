# redis

The one Redis every NDB Collection app shares: cache, the frontend's sessions, locks (scheduler, idempotency,
dashboard builds, RBAC rebuild), rate limits, the gateway's circuit breaker, the JWT denylist, the shared RBAC map and
the queues of the services with a worker. This repo builds its image; the apps' own code decides the keys. This file is
the cross-app key contract (NC-3927); the facts come from the apps' code and their CLAUDE.md "Shared Redis keys
(NC-3920)" sections.

## The image

| File | What it does |
|---|---|
| `Dockerfile` | `redis:8.10.3-alpine3.23` (pinned, NC-3909) plus `apk upgrade`; copies `redis.conf`; runs as the `redis` user; port 6379. `CMD` starts `redis-server redis.conf --maxmemory $REDIS_MAXMEMORY --maxmemory-policy $REDIS_MAXMEMORY_POLICY` and adds `--requirepass $REDIS_PASSWORD` only when that variable is set. Defaults: `REDIS_MAXMEMORY=1536mb`, `REDIS_MAXMEMORY_POLICY=noeviction` (NC-3919, NC-3920). `HEALTHCHECK`: `redis-cli ping` (with the password when set). |
| `redis.conf` | `bind 0.0.0.0`, `protected-mode no`, `databases 16`; AOF on (`appendfsync everysec`, `dir /data`); `maxmemory 1536mb` and `maxmemory-policy noeviction` as defaults (the `CMD` flags override them). |
| `docker-compose.yml` | Local run on its own: container `my-redis`, `127.0.0.1:6379`, data in `./data`, network `micro_net`. Its `command` replaces the image `CMD`: **no password**, and `redis.conf`'s memory lines apply. The workspace root compose builds the same image from `./redis`, also without a password. |

In Kubernetes (workspace Helm chart, `templates/redis.yaml`): one StatefulSet replica with a 5 Gi `ReadWriteOnce`
volume, `REDIS_MAXMEMORY` / `REDIS_MAXMEMORY_POLICY` from `redis.maxmemory` / `redis.maxmemoryPolicy`, `REDIS_PASSWORD`
from the release secret (optional, empty = no auth), probes `redis-cli ping`. A single instance is the agreed design:
when it is down, login, every gateway call (RBAC map, denylist), the frontend sessions and the scheduler locks fail.

**`noeviction`**: a full Redis refuses writes (visible errors) instead of silently dropping sessions, the RBAC map,
the denylist (a logged-out token would work again), locks or queued jobs. So every key an app writes must have a TTL
(except the RBAC map, which is rebuilt when missing), and memory needs an alert at about 80 % of `maxmemory`.

## How a key is named

Every app uses Laravel's Redis cache store and phpredis. A key's raw name in Redis is a connection prefix, then (for
cache keys and cache locks) a cache prefix, then the key the code uses.

| Kind | Raw key | Redis DB | Settings |
|---|---|---|---|
| An app's own cache value | `REDIS_PREFIX` + `CACHE_PREFIX` + key | `REDIS_CACHE_DB` (1) | connection `cache` |
| An app's own cache lock (`Cache::lock`, scheduler mutexes) | `REDIS_PREFIX` + `CACHE_PREFIX` + key | `REDIS_DB` (0) | `lock_connection` `default` |
| An app's queue | `REDIS_PREFIX` + `queues:<queue>` (and `:reserved`, `:delayed`, `:notify`) | `REDIS_DB` (0) | connection `default` |
| Frontend session | `REDIS_PREFIX` + `CACHE_PREFIX` + session id | `REDIS_SESSION_DB` (2) | connection `session` |
| Shared key (several apps) | `SHARED_REDIS_PREFIX` + `SHARED_CACHE_PREFIX` + key | `SHARED_REDIS_DB` (1) | store `shared`, connection `shared` |

Per-app prefixes (NC-3920, defaults in each app's `config/database.php` and `config/cache.php`; the Helm templates set
the same values): `REDIS_PREFIX` = `ndb_<app>_`, `CACHE_PREFIX` = `ndb_<app>_cache_`, with `<app>` one of `gateway`,
`frontend`, `auth`, `agency`, `campaign`, `communication`, `customer`, `dashboard`, `disposal`, `reference_data`,
`report`, `workflow`. Example: the gateway's breaker key `upstream_circuit:customer-service:open_until` is
`ndb_gateway_ndb_gateway_cache_upstream_circuit:customer-service:open_until` in DB 1.

The shared prefixes are `smartcollect-database:` + `smartcollect-cache:` in DB 1 (Helm `SHARED_REDIS_PREFIX`,
`SHARED_CACHE_PREFIX`, `SHARED_REDIS_DB`): where these keys were before NC-3920, so they did not move. Change the three
only together, in every app at once.

Values are written by Laravel's `RedisStore`: PHP `serialize()` for everything except plain numbers (stored as they
are). Only PHP/Laravel code can read the shared values; a reader in another language needs a format change first.

Rule: an app reads and writes only its own prefix, plus the shared keys below through `Cache::store('shared')`. It
never reads another app's own keys.

## Cross-app keys (shared store)

| Key | Writer | Readers | Value | TTL |
|---|---|---|---|---|
| `rbac:group_privileges` | auth-service `CacheGroupPrivilegesAction` (login when missing, every grant/revoke, `rbac:refresh` every 15 min); a backend service's `SharedGroupPrivileges` when it finds the map missing | api-gateway `CheckEndpointPermission`; every backend service's `checkRBAC()` (`SharedGroupPrivileges`) | `[groupId => [privilegeCode => true]]` | none (`forever`); replaced in one write, never deleted first. Missing: the gateway answers 503 `RBAC_UNAVAILABLE`, a service rebuilds it from Oracle |
| `rbac:rebuild` (lock) | whoever rebuilds the map: auth (waits 10 s), a backend service (waits 5 s) | the same | Laravel lock owner token | 30 s |
| `revoked_tokens:<jti, or sha256 of the token>` | auth-service `JwtDenylist` (logout) | auth-service (`SetAuthFromHeader`, logout), api-gateway `ValidateJwt` (`App\Support\JwtDenylist`) | `true` | until the token can no longer be refreshed |
| `refreshed_tokens:<jti, or sha256 of the token>` | auth-service `RefreshedTokens` | auth-service only (shared so every auth pod sees it) | time of the first refresh (Unix seconds) | until the token can no longer be refreshed |

The frontend reads no shared key. Its `groupPrivilegeCodes` (below) is its own copy, from reference-data `GET rbac`.

## Keys one app shares between its own pods

Own prefix, but written and read by different pods (web and worker, or every replica), so their names and formats are
a contract inside that app.

| Key (after the app's prefixes) | App | Writer → readers | Value | TTL |
|---|---|---|---|---|
| `idem:<user id or guest>:<Idempotency-Key>` | customer, agency, communication, disposal, workflow (`EnsureIdempotency`, routes with the `idempotent` middleware) | the web pod that ran the write → any web pod that gets the repeat | `{fingerprint, status, content_type, body}` of a 2xx answer | 24 h |
| `idem:<user id or guest>:<Idempotency-Key>:lock` (lock) | the same | the call running the write; another call with the key gets 409 `REQUEST_IN_PROGRESS` | lock owner | 30 s |
| `queued-export:<uuid>` | report, dashboard, reference-data (`QueuedExportStore`, NC-3926) | web pod (`queued`), worker (`running`, `done`, `failed`) → the `export-jobs/{id}` status endpoint | `{id, userId, status, url, message, queuedAt}` | `QUEUED_EXPORT_STATUS_TTL_SECONDS` (24 h) |
| queue `<app>-default` (`queues:report-default`, `queues:dashboard-default`, `queues:reference-data-default`) | report, dashboard, reference-data (`QUEUE_CONNECTION=redis`, `REDIS_QUEUE` in Helm) | web and scheduler pods → the app's worker | Laravel job payload | until processed; `retry_after` 660 s |
| `<cache key>:build` (lock) | dashboard (`StampedeSafeCache`, NC-3925) | the first request that builds a cold widget key; the others wait up to 15 s | lock owner | 60 s |
| `workflow-case:<loanMasterId>:<wkMainId>` (lock) | workflow (`WorkFlowCaseController`, add case) | one add-case call per loan and workflow; others wait up to 5 s | lock owner | 30 s |
| `upstream_circuit:<service>:failures` | api-gateway (`CircuitBreaker`, NC-3923) | every gateway pod | failure count | `GATEWAY_BREAKER_WINDOW` (30 s) |
| `upstream_circuit:<service>:open_until` | api-gateway | every gateway pod (fast 503 while open) | Unix time the circuit may close | cooldown + 600 s |
| `upstream_circuit:<service>:probe` | api-gateway | the one half-open probe call | `1` | the service's timeout + 5 s |
| `login:<sha256(lower(trim(username)) + "\|" + client IP)>` and `...:timer` | api-gateway (`LoginThrottle`, NC-3924) | every gateway pod | attempt count / window end | `RATE_LIMIT_LOGIN_DECAY_SECONDS` (60 s) |
| per-user API limit and wallboard limit (`api-user:<token sub>`, `wallboard:<client IP>`) and `...:timer` | api-gateway (`throttle:api-user`, `throttle:wallboard`) | every gateway pod | call count / window end | 60 s |
| scheduler mutexes `framework/schedule-<sha1>` (`withoutOverlapping`) and the same with `HHMM` appended (`onOneServer`) | auth, agency, communication, customer, dashboard, report, workflow schedulers | every scheduler replica of that app | lock owner | the minutes given to `withoutOverlapping` (e.g. 720 for the daily jobs, 10 for `rbac:refresh`); 1 h for `onOneServer` |
| session id | frontend (`SESSION_DRIVER=redis`, NC-3920) | every frontend pod | the session: `ses_jwt_token`, `user`, `menusVerticle`, `menusHorizontal`, `notificationList`, flash data | `SESSION_LIFETIME` (120 min) |
| `groupPrivilegeCodes` | frontend (`App\Support\GroupPrivilegeCodes`) | every frontend pod (`checkRBAC()`, `check.rbac`); the group privilege screen's clear reloads it | `{groupId: [privilege codes]}` from reference-data `GET rbac` | 15 min |

The rate-limit keys are counted by Laravel's `RateLimiter` in the gateway's default cache store; for the named limiters
(`api-user`, `wallboard`) Laravel's `ThrottleRequests` stores the key hashed (md5 of the limiter name and the key), so
the raw name is not readable as written above. The other apps' own cache entries (lists, dashboard widgets, the
`api` route limiter) are private to each app and not listed.

## Changing a key

- Adding a key in an app's own prefix needs nothing here, as long as it has a TTL (`noeviction`).
- A cross-app key (the shared store) or a key in the second table: its name, value shape and TTL are a contract. A
  change ships so that old and new pods work side by side: the readers first learn to read both forms, then the writer
  switches, then the old form is dropped in a later release. Moving the shared store (`SHARED_*` values, DB number)
  is a change to every app at once.
- Update this README and the "Shared Redis keys (NC-3920)" section of every app's CLAUDE.md in the same change.
