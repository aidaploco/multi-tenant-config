# gitops/ — reconciled by Config Sync (ADR-0012)

Config Sync continuously applies this directory to the shared runtime GKE cluster. It is the
declarative, self-healing source of the cluster's configuration — not imperative `kubectl`.

## What lives here

| Path | What | Owner |
| ---- | ---- | ----- |
| `cluster/` | Cluster-scoped baseline (shared platform namespaces, and later Policy-Controller guardrails). Tenant-independent. | Config Sync |
| `namespaces/tenant-template/` | **The contract** a tenant namespace must satisfy: default-deny `NetworkPolicy`, `ResourceQuota`, `LimitRange`, namespace-scoped RBAC. | (template) |

## Division of labor (ADR-0012 D12-3)

- **Per-tenant namespaces are created by Terraform** (the tenant composition, data-driven via
  `for_each`) — *not* by per-tenant files here. That keeps onboarding data-driven (one YAML, no
  generator). `tenant-template/` shows the shape Terraform stamps per opted-in tenant.
- **Config Sync reconciles the cluster-wide policy** and (later) Policy-Controller constraints that
  *enforce* every tenant namespace carries the contract — defense in depth.

## The isolation contract (why a tenant is safe next to another)

For each tenant namespace:
- **`default-deny-ingress`** — no pod in any other tenant's namespace can reach in.
- **`allow-same-namespace`** — a tenant's own pods can talk to each other.
- **`ResourceQuota` + `LimitRange`** — a noisy tenant can't starve the cluster.
- **namespace-scoped `RoleBinding`** — the tenant's group has rights *only* in its namespace.

> Until Config Sync is installed **and** per-tenant namespaces exist, the shared cluster is not yet
> multi-tenant safe (ADR-0009). This directory is validated as YAML; live reconciliation needs the
> cluster.
