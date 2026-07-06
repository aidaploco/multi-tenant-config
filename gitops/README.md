# gitops/ — reconciled by Config Sync (ADR-0012)

Config Sync continuously applies this directory to the shared runtime GKE cluster. It is the
declarative, self-healing source of the cluster's configuration — not imperative `kubectl`.

## Ownership contract (ADR-0012 D12-3, hardened after review)

Exactly one controller per object, ever:

| Owner | Objects | Where |
| ----- | ------- | ----- |
| **Config Sync** | Cluster-scoped baseline: platform namespaces, Policy-Controller guardrails. | `cluster/` |
| **Config Sync** | Per-tenant **app payload** (Deployments/Services — workload kinds only), **generated** from the registry by `scripts/render-payload.rb` (ADR-0017). Never hand-edit: CI re-renders and rejects drift. Objects are scoped per environment via `configsync.gke.io/cluster-name-selector: runtime-<env>`. | `payload/<env>/<tenant>/<unit>.yaml` |
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
- **`ResourceQuota` + `LimitRange`** — a noisy tenant can't starve the cluster.
- **namespace-scoped `RoleBinding`** — the tenant's group has rights *only* in its namespace.

Enforced cluster-wide from here: `cluster/deny-default-sa.yaml` (Policy Controller) blocks any
pod in a tenant namespace from running as the shared `default` SA (ADR-0015).

> Until Config Sync is installed **and** per-tenant namespaces exist, the shared cluster is not
> yet multi-tenant safe (ADR-0009). This directory is validated as YAML; live reconciliation
> needs the cluster.
