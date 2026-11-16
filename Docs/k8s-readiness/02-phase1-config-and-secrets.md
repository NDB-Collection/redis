# Phase 1: Configuration and secrets (Guideline 6)

**Target:** the same image runs in DEV/UAT/PROD with only environment variables and secrets changing.

## Steps
1. **`env()` only in `config/*.php`.** Move every `env()` call from `app/`, `routes/`, `resources/` into a config key (e.g. `config/<service>.php`)
   and read it with `config('<service>.x')`. Reason: after `config:cache`, `env()` outside config returns `null`.
2. **No hard-coded addresses.** Service URLs (`config/services.php` in gateway/frontend), DB TNS, Redis host, SMS/email
   gateways and file paths all come from env. Remove IPs/hosts from code.
3. **Timeouts are config too.** Add keys now (used in Phase 5): `SERVICE_CONNECT_TIMEOUT`, `SERVICE_TIMEOUT`, per-service overrides.
4. **Secrets vs config.** Split `.env.example` into two clearly commented blocks:
   - Config (ConfigMap): `APP_ENV`, `APP_URL`, `LOG_CHANNEL`, service URLs, timeouts, feature flags
   - Secrets (Secret): `APP_KEY`, `DB_USERNAME`, `DB_PASSWORD`, `DB_TNS` (if it carries credentials), `JWT_PRIVATE_KEY_BASE64` (auth only), Redis password, SMS/email API keys
5. **`APP_KEY`:** one value per service per environment, shared by **all replicas of that service**. This is critical for
   `frontend`, because sessions and cookies are encrypted with it. Never commit real keys. `.env.example` keeps an empty value.
6. **JWT keys:** public key stays committed (it isn't secret). The private key only exists in auth-service, only from a Secret.
7. **Production settings:** `APP_DEBUG=false`, `APP_ENV=production`, `LOG_CHANNEL=stderr` (see Phase 4).
8. **Trusted proxies:** behind ingress, configure `TrustProxies` (env `TRUSTED_PROXIES`) so scheme, client IP
   and generated URLs are correct.
9. **Config caching at container start, not at image build:** entrypoint script:
   ```sh
   php artisan config:cache && php artisan route:cache && php artisan view:cache
   exec "$@"
   ```
   Build-time caching would freeze the build machine's env into the image.
10. **Feature flags:** simple `config('features.x')` booleans from env. No package.
11. **Remove `.env` from images:** add it to `.dockerignore` and keep secrets out of the git history going forward. Report any committed secrets you find. Don't rewrite history.

## Done when
- `grep -rn "env(" app routes resources` returns nothing.
- App boots with `config:cache` using only injected env vars.
- `.env.example` lists every key, split into config and secret blocks.

> **STOP.** Show the moved `env()` calls and the final key list.
