# Final readiness checklist (per repo)

Copy this to `Docs/k8s-readiness/<repo>-signoff.md` and tick each item with evidence (test name, log sample, file).

## Config & secrets (6)
- [ ] No `env()` outside `config/`. No hard-coded hosts or credentials
- [ ] `.env.example` split into config / secret. No secrets in the image or repo
- [ ] `config:cache`/`route:cache` run at container start
- [ ] `APP_DEBUG=false`, trusted proxies set, `APP_KEY` the same across replicas

## Stateless (1)
- [ ] Sessions and cache on Redis with a per-service prefix
- [ ] Persistent files on shared storage. Only temp files on local disk
- [ ] Locks via `Cache::lock`. No host-specific logic
- [ ] Verified with 2 replicas plus killing one mid-session

## Health & lifecycle (7)
- [ ] `/health/live` (no deps), `/health/ready` (Oracle + Redis only)
- [ ] Graceful shutdown: preStop sleep, php-fpm SIGQUIT, grace period set
- [ ] Long requests moved to jobs, or listed with an agreed plan

## Logging (9)
- [ ] JSON to stderr, `X-Request-ID` generated/forwarded/returned, in job logs too
- [ ] No tokens, passwords or full NIC/account numbers in logs
- [ ] Gateway logs upstream status and latency per service

## Communication & degradation (2, 3)
- [ ] Connect and request timeouts on every outbound call. Budgets nest correctly
- [ ] Retries only for idempotent requests, max 2, with backoff + jitter, at one layer
- [ ] Circuit breaker per target. Fast 503 when open
- [ ] Standard error envelope. Business errors vs technical errors
- [ ] Operation matrix filled and agreed

## Security (5)
- [ ] JWT: alg pinned, exp/iss checked, short TTL
- [ ] Scopes enforced in the service, not only at the gateway. Policies for resource-level access
- [ ] Service tokens for system calls. NetworkPolicy request sent to infra
- [ ] Rate limiting on login and the API. Response fields minimised/masked
- [ ] OWASP API Top 10 reviewed

## Data integrity & DB (4, 10)
- [ ] Critical writes have an Idempotency-Key (and a natural unique rule where agreed)
- [ ] Optimistic/pessimistic locking where concurrent edits matter. Deadlock retry
- [ ] No HTTP calls inside transactions. Jobs dispatched after commit
- [ ] Connection budget calculated and within the Oracle limit
- [ ] Lazy-loading prevention on in non-prod. N+1 fixed. No unbounded queries
- [ ] Migrations follow expand/contract

## Jobs & schedule (8)
- [ ] Separate web / worker / scheduler (1 replica) commands
- [ ] Timeout order: job < worker < retry_after < grace period
- [ ] Jobs idempotent, with tries/backoff/failed(). Schedule has onOneServer + withoutOverlapping
- [ ] Failed-job runbook and alert

## Contracts (11)
- [ ] OpenAPI file present and reviewed
- [ ] Change rules in CLAUDE.md. Contract tests for the fields consumers use
- [ ] Rollback plan: previous image tag + additive migrations + feature flags

## Sign-off
| Repo | Reviewer | Date | Open gaps (ticket) |
|---|---|---|---|
