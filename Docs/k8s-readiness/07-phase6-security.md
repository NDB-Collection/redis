# Phase 6: Authentication, authorization, service security (Guideline 5)

**Principle:** a request isn't trusted just because it came from inside the cluster. Each service checks *who the user is*,
*who the caller is* and *whether this operation on this record is allowed*.

## Current state (from the architecture)
- auth-service signs JWTs (private key). The gateway validates (`ValidateJwt`) and checks route scopes (`CheckEndpointPermission`).
- Services verify the JWT signature with the public key (`jwt` guard), but **scope/permission checks happen only at the gateway**.
  If someone reaches a service directly (another pod, a port-forward, a mistake in the ingress), any valid token can call any endpoint.

## Steps
1. **Token validation in every service (already partly there):** check the signature, `exp`, `nbf`, a pinned algorithm (RS256 only),
   `iss` = auth-service, and `aud` if added. Reject tokens with no expiry. Keep access-token TTL short (e.g. 15 min) and use refresh tokens.
2. **Authorization at the service boundary (defence in depth):** each service enforces the same scopes the gateway
   enforces for its routes:
   - Move the scope list for a service's routes into that service (route middleware `scope:customer.view`), reading scopes from the JWT claims.
   - The gateway keeps its check (fast reject). The service check is the real authority.
   - Agree with the team that one source of scope definitions per route (the gateway's `config/routes/<service>.php`) gets copied or synced into the service.
3. **Resource-level checks (Policies):** "may view customer X" doesn't follow from "has customer.view".
   Use Laravel Policies/Gates for branch, region, allocation ownership and agency boundaries (e.g. an agency user only sees accounts assigned to their agency; a collector only sees allocated accounts if that's the rule). Ask which rules apply per role.
4. **Service-to-service authentication:**
   - User context: forward the user's JWT (already done by the gateway). The service authorizes as that user.
   - System calls (jobs, scheduler, service → service without a user): use a **service token** signed by auth-service
     (client-credentials style, `sub=service:<name>`, its own scopes, short TTL) and cache it until expiry. Don't use shared static API keys.
   - **Network:** NetworkPolicy so services accept traffic only from the gateway (and named callers). Only frontend and gateway get an ingress.
5. **Input validation:** FormRequest on every write. Whitelist the fields (`validated()`, no `$request->all()` into `create()`/`update()`).
   Validate path IDs belong to the user's scope (point 3).
6. **Rate limiting:** at the gateway, using Laravel `RateLimiter` on Redis (shared across replicas):
   login per IP + username (brute force), and general API per user. Return `429` with `Retry-After`.
7. **Sensitive data exposure:** API Resources return only the needed fields. Mask NIC/account/card/phone where the screen doesn't need the full value.
   No stack traces (`APP_DEBUG=false`). Remove unused debug endpoints.
8. **Secrets:** Phase 1 rules. Rotate the JWT key pair with a `kid` header so two public keys can be valid during rotation.
9. **CORS:** the gateway allows only the frontend origin (NC-3838). Keep that list in env per environment.
10. **OWASP API Top 10 check:** go through the list (BOLA, broken auth, BOPLA, unrestricted resource use, BFLA, …) and record per repo: covered / gap / N/A.

## Tests
- Direct call to a service with a valid token but without the scope → `403`.
- Token signed with a different key / `alg=none` / expired → `401`.
- Agency user requesting another agency's account → `403`.
- Login brute force → `429`.

> **STOP.** Show the scope mapping per service and the OWASP checklist.
