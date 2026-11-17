# gitops/ — reconciled by Config Sync (ADR-0012)

Config Sync continuously applies this directory to the shared runtime GKE cluster. It is the
declarative, self-healing source of the cluster's configuration — not imperative `kubectl`.

## Ownership contract (ADR-0012 D12-3, hardened after review)

Exactly one controller per object, ever:

| Owner | Objects | Where |
| ----- | ------- | ----- |
| **Config Sync** | Cluster-scoped baseline: platform namespaces, Policy-Controller guardrails. | `cluster/` |
| **Config Sync** | Per-tenant **app payload** (Deployments/Services, plus the ConfigMaps a unit's `manifest_ref`/`packs_ref` render from `config/` — workload kinds only), **generated** from the registry by `scripts/render-payload.rb` (ADR-0017, ADR-0022). Never hand-edit: CI re-renders and rejects drift. Objects are scoped per environment via `configsync.gke.io/cluster-name-selector: runtime-<env>`. | `payload/<env>/<tenant>/<unit>.yaml`, `payload/<env>/<tenant>/_config-<ref>.yaml` |
| **Config Sync** | Per-tenant **trace backend** (one Phoenix instance per tenant per environment: ServiceAccount, PVC, Deployment, Service, NetworkPolicy), **generated** from the registry by the same renderer (ADR-0027). Every object lives in `platform-system` — never a tenant namespace — which is why the ownership guard admits `ServiceAccount`/`NetworkPolicy` under `platform/` (only for `platform-system`) and nowhere outside `cluster/`. Same drift rule: never hand-edit. | `platform/<env>/phoenix-<tenant>.yaml` |
| **Terraform** | Tenant namespaces and ALL their **policy objects**: `Namespace`, `NetworkPolicy`, `ResourceQuota`, `LimitRange`, RBAC, `ServiceAccount` (the `tenant-namespace` module, data-driven). | `terraform/tenant-runtime/` |

Nothing Terraform-owned may appear in this tree. Concrete tenant manifests used to live here
(`namespaces/tenant-template/` with real `abf` values) — that meant Config Sync and Terraform
both managed namespace `abf`, fighting on every reconcile and resurrecting namespaces on
offboard. The reference copy now lives in
[`docs/runtime/tenant-namespace-contract/`](../docs/runtime/tenant-namespace-contract/), outside
the synced tree, and **CI enforces the boundary**: `scripts/check-gitops-ownership.rb` fails the
build if a Terraform-owned policy kind shows up anywhere under `gitops/` outside `cluster/`.

## The isolation contract (why a tenant is safe next to another)

Stamped per tenant by Terraform (see the reference copy above):

- **`default-deny-ingress`** — no pod in any other tenant's namespace can reach in.
- **`allow-same-namespace`** — a tenant's own pods can talk to each other.
- **default-deny egress + an explicit allow-list** — DNS, same-namespace, `platform-system`, and
  the external internet minus private ranges (ADR-0022 D22-4, `tenant-namespace` v0.12.0).
- **`ResourceQuota` + `LimitRange`** — a noisy tenant can't starve the cluster.
- **namespace-scoped `RoleBinding`** — the tenant's group has rights *only* in its namespace,
  narrowed to `view` + a contract-shaped operate Role (ADR-0023, v0.13.0): tenants cannot write
  or delete NetworkPolicies.

Enforced cluster-wide from here: `cluster/deny-default-sa.yaml` blocks any pod in a tenant
namespace from running as the shared `default` SA (ADR-0015); `cluster/exact-unit-ksa.yaml`
goes further — a pod must run as one of the tenant's own **unit KSAs**, read from the
namespace's `unit-ksas` annotation via `cluster/gatekeeper-sync.yaml`'s referential-data sync,
and fails closed if that sync is missing (ADR-0018). Both are **live-verified** on a local kind
cluster (`scripts/kind/up.sh`), not merely reviewed — see `docs/VERIFICATION.md`.

> Until Config Sync is installed **and** per-tenant namespaces exist on a REAL GKE cluster, the
> shared cluster is not yet multi-tenant safe (ADR-0009) — that GKE/Fleet-specific half is
> still unverified. The logic itself (reconciliation, pruning, admission enforcement) is
> verified live on kind (ADR-0018).
