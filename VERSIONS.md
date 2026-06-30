# Module versions

Single source of truth for which version of every `platform-modules` module is deployed.
**Upgrading a module = bump the ref here + in the Terraform source + open a PR.** A CI check
enforces that the `?ref=` in the Terraform matches the version recorded here.

Modules are consumed from:
`git::https://github.com/aidaploco/multi-tenant-platform.git//modules/<name>?ref=<version>`

| Module | Version | Notes |
| ------ | ------- | ----- |
| `gcp-project` | `v0.1.0` | Tenant project + APIs + labels |
| `kms-tenant` | `v0.1.0` | Per-tenant CMEK keyring + keys |
| `gcs` | `v0.1.0` | CMEK-encrypted, private buckets |
| `observability` | `v0.1.0` | Log sink + alerts + dashboard |
| `agent-identity` | `v0.2.0` | Agent-unit archetype: runtime SA + WI binding + IAM |
| `shared-vpc` | `v0.4.0` | Runtime-plane private network (PGA, NAT, default-deny) |
| `gke-autopilot` | `v0.5.0` | Shared runtime cluster (private Autopilot + Workload Identity) |
| `cloud-composer` | `v0.6.0` | Shared managed-Airflow plane (private environment + own SA) |

> `v0.1.0` is the initial MVP module library. Going forward, `platform-modules` versions are
> cut automatically by semantic-release on merge to `main` (conventional commits).

## Two version namespaces — don't confuse them (ADR-0002 D2-3)

This file tracks **platform-module versions** (infra building blocks). It is the **only** place
those are pinned, and drift across tenants is a smell to converge.

**Unit versions** (`search-a: 1.4.0` in a tenant's registry YAML) are a *different* namespace:
they pin a workload/app *release* per tenant per environment, and independent drift there is
expected — it is the whole point of axis 2. A `data-unit@1.4.0` still consumes `gcs@<version
above>` internally. Per-unit pinning must never leak into per-unit infra-module pinning.
