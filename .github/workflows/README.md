# CI/CD Workflows — redis

Reusable actions live in
[`NDB-Collection/xgen-git-workflows`](https://github.com/NDB-Collection/xgen-git-workflows).

| Workflow | Purpose |
|----------|---------|
| `build.yml` | CI docker build on PR/push; on-demand image build & ECR push (`:latest`) |
| `release.yml` | Build & push a versioned image, tag the repo, create a GitHub Release |
| `trivy-scan.yml` | Filesystem and image vulnerability scan |

Deployment is handled outside these pipelines — they take the image as far as
ECR. The image is environment-agnostic: runtime config (DB, secrets, URLs) is
injected by ECS from the task definition and Secrets Manager, so neither
workflow takes an `env` input.

## Naming

| Item | Value |
|------|-------|
| ECR repository | `xgen-ndb-redis` |

## Required configuration

Settings → Secrets and variables → Actions:

| Name | Type | Value |
|------|------|-------|
| `CICD_AWS_ROLE_ARN` | secret | OIDC role ARN GitHub Actions assumes |

`xgen-git-workflows` is a private repo in the same org. For this repo to consume
its actions, set Settings → Actions → General → Access on
`NDB-Collection/xgen-git-workflows` to allow access from repositories in the
`NDB-Collection` organization.

## Commands

Run with the GitHub CLI from the repo root.

### Build (ad-hoc ECR push)

Runs automatically on pull requests and pushes to `dev`/`main` (build only,
nothing pushed). To build and push `:latest`:

```bash
gh workflow run build.yml
```

### Release

```bash
gh workflow run release.yml -f version=1.0.0
```

Produces git tag `1.0.0`, a GitHub Release, and ECR images tagged `1.0.0`
and `latest`.

Optional on both: `-f aws-region=ap-southeast-2` (default).

> The ECR repository `xgen-ndb-redis` must exist before the first build or release.
