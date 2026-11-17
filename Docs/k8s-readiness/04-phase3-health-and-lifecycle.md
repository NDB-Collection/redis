# Phase 3: Health checks, lifecycle, graceful shutdown (Guideline 7)

**Target:** Kubernetes can tell *started*, *ready* and *alive* apart, and a terminating pod finishes in-flight work.

## Steps
1. **Three endpoints**, outside the `jwt` group, no session, no logging noise. Exclude them from the gateway proxy, because K8s calls each pod directly.

| Endpoint | Probe | Checks | Must NOT check |
|---|---|---|---|
| `GET /health/live` | liveness | PHP responds (return `200 {"status":"ok"}`). Laravel 11+ `/up` is fine. | DB, Redis, other services |
| `GET /health/ready` | readiness | Oracle `select 1 from dual` (timeout ≤ 2s), Redis `PING`, config cached | **other microservices** |
| same as ready | startup | (as ready, with a longer `failureThreshold`) | |

   Why: if customer-service restarts because Oracle is slow or campaign-service is down, you get restart storms.
   Liveness = "is this process broken". Readiness = "can I serve right now".
   The gateway's readiness checks only the gateway's own Redis, not the 10 services.
2. **Keep the endpoint cheap:** a single controller, no Eloquent, short timeouts, `Cache` the DB check result for ~5s to avoid DB load from probes.
3. **Startup work:** no DB calls or HTTP calls in service providers' `boot()`. Warm-up (config/route cache) is in the entrypoint (Phase 1).
4. **Graceful shutdown (web pods, nginx + php-fpm):**
   - `preStop` on nginx: `sleep 10`. This gives the endpoint removal time to propagate so no new requests arrive.
   - php-fpm: graceful stop with `SIGQUIT` (configure `STOPSIGNAL SIGQUIT` in the Dockerfile) so running requests finish. Set `process_control_timeout` (e.g. `30s`).
   - `terminationGracePeriodSeconds` > preStop + longest normal request (e.g. 45s).
5. **Long requests:** anything that can exceed ~30s (big exports, allocation run, bulk SMS) moves to a queued job
   (Phase 8) and returns `202` + a job/status id. Record which endpoints need this. Changing them is an API change, so ask first.
6. **Manifests (hand to infra, keep in `deploy/` if the repo has one):** document per repo the probe paths,
   ports, `initialDelay`/`period`/`timeout`/`failureThreshold`, resource requests/limits, and `terminationGracePeriodSeconds`.

## Example probe block (for the infra team)
```yaml
startupProbe:   { httpGet: { path: /health/ready, port: 8080 }, periodSeconds: 5, failureThreshold: 24 }
readinessProbe: { httpGet: { path: /health/ready, port: 8080 }, periodSeconds: 10, timeoutSeconds: 3, failureThreshold: 3 }
livenessProbe:  { httpGet: { path: /health/live,  port: 8080 }, periodSeconds: 15, timeoutSeconds: 3, failureThreshold: 3 }
terminationGracePeriodSeconds: 45
lifecycle: { preStop: { exec: { command: ["sh","-c","sleep 10"] } } }
```

> **STOP.** Show the endpoints, their response times, and the list of long-running endpoints.
