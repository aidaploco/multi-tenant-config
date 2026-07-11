# Module versions

Single source of truth for which version of every `platform-modules` module is deployed.
**Upgrading a module = bump the ref here + in the Terraform source + open a PR.** The
`versions-check` workflow (`scripts/check-versions.sh`) **fails the PR** if any `?ref=` in the
Terraform disagrees with this file — drift cannot merge. The OPA policy gate auto-tracks the
**latest** version listed here, so guardrails never lag the modules.

> **Maintenance note (things this check does *not* cover):** the Composer `image_version` and the
> pinned GitHub Actions versions also age out and must be bumped manually on a periodic sweep.

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
| `config-sync` | `v0.9.0` | GitOps loop (Config Sync via Fleet) + Policy Controller |
| `tenant-namespace` | `v0.12.0` | Per-tenant cluster namespace isolation (default-deny, quota, WI SA, RBAC). v0.11.0: `unit-ksas` namespace annotation feeding the exact-KSA constraint (ADR-0018). v0.12.0: default-deny egress + explicit allow-list (DNS, same-namespace, platform-system, external-minus-private-ranges) + `extra_egress_cidrs` escape hatch (ADR-0022) |
| `policies` (OPA gate) | `v0.10.0` | Not a module — the policy dir the opa-gate consumes. The gate resolves the **latest** version in this file, so this row also drives the gate's ref. v0.10.0: real destroy-threshold override (offboarding). |

> `v0.1.0` is the initial MVP module library. Tags are cut **manually** (`git tag vX.Y.Z` +
> push) — there is no release automation yet; semantic-release on conventional commits is
> tracked as a nice-to-have, not something this repo can assume.

## Two version namespaces — don't confuse them (ADR-0002 D2-3, ADR-0011)

This file is the **single, fleet-wide source of truth** for **platform-module versions**. Every
tenant runs the same module versions — there is **no** per-tenant module version in the registry
(by decision: one platform, not a zoo). A bad module bump rolls back fleet-wide, caught in dev
first. Per-tenant module divergence is the rare held-back-tenant exception = the generator
graduation, deliberately not a default.

**Unit versions** (`search-a: 1.4.0` in a tenant's registry YAML) are a *different* namespace: a
workload's *app* release, optional and archetype-specific (an identity-only `agent-unit` has
none). A `data-unit@1.4.0` still consumes `gcs@<version above>` internally. A unit's app version
must never be mistaken for a platform-module pin.
