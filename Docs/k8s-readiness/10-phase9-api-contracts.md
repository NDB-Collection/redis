# Phase 9: API contracts and independent deployments (Guideline 11)

**Target:** gateway, frontend and any service can be deployed or rolled back alone, and old and new versions can run side by side during a rollout.

## Steps
1. **Document the contract:** one OpenAPI 3 file per service (`docs/openapi.yaml`), covering the paths, methods, request fields,
   response envelope, error codes (Phase 5.5) and required scopes. Generate a first draft from the routes + FormRequests + Resources,
   then review it by hand. Ask before adding a generator package (e.g. a scribe/l5-swagger style tool).
2. **Change rules (write them in each repo's CLAUDE.md):**
   - Allowed without a version bump: add an endpoint, add an optional request field, add a response field.
   - Breaking (needs a new version or a deprecation window): remove/rename a field or endpoint, make a field required, change a type or meaning, change an error code.
   - Consumers must **ignore unknown response fields** (frontend/gateway).
3. **Versioning:** keep current routes as v1 (no URL change now). For a breaking change, add `/api/v2/...` next to v1,
   move the frontend, then remove v1 in a later release. The gateway route config gets the v2 entry first.
4. **Rollout order** for a feature touching several repos: DB expand → service (backward compatible) → gateway config → frontend → (later) contract/cleanup.
5. **Validation both sides:** services validate requests (FormRequest). Optionally the gateway validates the response
   envelope shape and logs violations (don't block).
6. **Contract tests (minimal first step):** a feature test per endpoint asserting the status and `assertJsonStructure`
   from the OpenAPI example. The frontend/gateway team lists the fields they actually use per endpoint (consumer-driven), and those tests protect them.
   Pact is optional later.
7. **Database compatibility:** expand/contract (Phase 7.6). A rollback of the service must still work with the expanded schema.
8. **Rollback plan per release:** previous image tag recorded, migrations in that release are additive only, feature flags (Phase 1)
   used to switch off new behaviour without a redeploy.

> **STOP.** Show the OpenAPI file and the contract tests added.
