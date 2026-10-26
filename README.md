# multi-tenant-config

The tenant registry, deployment roots, policies, and CI/CD for the multi-tenant GCP data
platform. This is **REPO 2** of two; it consumes versioned modules from
[`multi-tenant-platform`](../multi-tenant-platform) by **pinned git tag**.

See [`docs/adr/0001-platform-architecture.md`](docs/adr/0001-platform-architecture.md) for the
full architecture and rationale.

## What lives here

| Path | Purpose |
| ---- | ------- |
| [`tenants/`](tenants/) | **One YAML per tenant** — the entire onboarding interface. |
| `terraform/tenants/` | The `for_each` root that reads every tenant YAML and loops. |
| `policies/` | OPA policies consumed from `multi-tenant-platform` (pinned). |
| `.github/workflows/` | Plan on PR, gated apply on merge (dev → acc → prod). |
| [`docs/`](docs/) | ADRs and runbooks. |
| [`VERSIONS.md`](VERSIONS.md) | The single source of truth for pinned module versions. |

## Onboard / change a tenant

1. Add or edit `tenants/<slug>.yaml` (see [the schema](tenants/README.md)).
2. Open a PR → CI runs `plan` + the policy gate and comments the diff.
3. Merge → auto-apply to **dev** → manual approval → **acc** → manual approval → **prod**.
   > The approval gates are GitHub **environment protection rules** on `acc`/`prod` — they exist
   > only once configured in repo settings (free on public repos). Until then, and while CI is
   > dormant (`WIF_PROVIDER` unset), no gate is actually enforced.

A new tenant is *new data in the registry*, not a new pipeline.

## Module versions

All modules are pinned to a released tag of `multi-tenant-platform`, never `main`. The current
pins are tracked in [`VERSIONS.md`](VERSIONS.md); a CI check enforces that the refs used in
Terraform match it.
