# Phase 2: Stateless apps and shared state (Guideline 1)

**Target:** any replica can serve any request, and a pod can be killed at any moment without losing data.

## Steps
1. **Sessions → Redis** (`frontend` especially: the JWT lives in session `ses_jwt_token`).
   `SESSION_DRIVER=redis`, dedicated `SESSION_CONNECTION`, and the same `APP_KEY` on all frontend replicas.
   Gateway and services are token-based: `SESSION_DRIVER=array` (they shouldn't need sessions).
2. **Cache → Redis** (`CACHE_STORE`/`CACHE_DRIVER=redis`). Never `file`.
3. **Redis key isolation** (one shared Redis): set a per-service `REDIS_PREFIX` and `CACHE_PREFIX`
   (e.g. `ndb_customer_`). Use separate Redis DB numbers for cache vs session vs queue if allowed.
4. **Files: temporary vs persistent.**
   - Temporary (build an export, then stream it): `sys_get_temp_dir()` / `storage/app/tmp`, deleted in the same request or job. Fine on local disk.
   - Persistent (generated reports, letters, uploaded documents, files another request or pod will read):
     move to a shared disk (`FILESYSTEM_DISK=s3` for MinIO/S3, or a disk on a RWX volume). Replace `Storage::disk('local')`
     and `storage_path()` writes with `Storage::disk(config('filesystems.shared'))`.
   - Report download flow: job writes to the shared disk → the download endpoint reads from the shared disk (not the pod that created it).
5. **No in-process state:** remove static properties or singletons that cache per-user/per-request data between requests
   (important if Octane is ever used). Use Redis cache with a TTL.
6. **Locks → Redis atomic locks:** replace `flock`, DB "IN_PROGRESS" flags without expiry, and file-based locks with:
   ```php
   Cache::lock("alloc:{$campaignId}", 300)->block(5, fn () => $this->allocate($campaignId));
   ```
   Lock TTL must be longer than the work. Release in `finally`.
7. **No server affinity:** remove reliance on hostname, local IP, `gethostname()` in business logic, or a cron on "server 1".
8. **Logs** don't go to local files (Phase 4).

## Verify
Run 2 replicas locally (`docker compose up --scale frontend=2 --scale gateway=2`) behind a round-robin proxy.
Log in, open several screens and export a report: everything works no matter which replica serves it. Kill one replica mid-session: the user stays logged in.

> **STOP.** Report which files moved to shared storage and which locks were added.
