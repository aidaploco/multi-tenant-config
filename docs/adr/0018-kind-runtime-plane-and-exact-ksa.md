# ADR-0018: Local kind runtime plane + the exact-KSA constraint

- **Status:** Accepted — live-verified on kind 2026-07-07
- **Date:** 2026-07-06
- **Builds on:** ADR-0009 (GKE cluster), ADR-0012 (Config Sync ownership), ADR-0013 (namespace
  isolation contract), ADR-0015 (shared-compute isolation, deny-default-sa), ADR-0017 (payload
  delivery + `cluster-name-selector` scoping).
- **Amends:** ADR-0015's isolation model — deny-default-sa is necessary but not sufficient.

---

## Context

Everything in `terraform/tenant-runtime` and `gitops/cluster/` was, until now, **reviewed, not
verified**: real Kubernetes manifests and Terraform resources that had never actually reached a
live API server. `terraform plan` on `tenant-runtime` required real GCP credentials via
`data.google_project` even to *read* — the project has none (deliberate, cost) — so the whole
plane was a paper design. M2's job is to close that gap the only way possible without a cloud
org: a local Kubernetes cluster real enough to apply the same resources to.

A second gap surfaced while designing this: ADR-0015's `deny-default-sa` constraint stops a pod
from running as the shared `default` SA, but says nothing about a pod running as *some other*
named SA that isn't the tenant's own unit identity. A compromised or misconfigured pod could
create any SA in its own namespace and run as that — satisfying "not default" while still not
being the SA Workload Identity (and, per ADR-0016, the Temporal codec) is keyed to.

## Decisions

**D18-1. `cluster_mode = kind | connectgateway` on `terraform/tenant-runtime`, same resources
either way.** GCP-only data sources (`google_project`, `google_client_config`) are count-gated
to zero in kind mode; the `kubernetes` provider points at the kind kubeconfig context
(`kind-runtime-<env>`) instead of Connect Gateway. The `tenant_namespace` module itself is
untouched — namespaces, NetworkPolicies, quota, RBAC, and KSAs are identical resources in both
modes. **This is deliberate:** kind is not a separate, simplified re-implementation that could
drift from the real thing; it is the *same* Terraform hitting a different Kubernetes API.

*Local plane implementation detail (not a design decision, just what it took to run):*
Kubernetes ≥ 1.34's kubelet refuses to start under cgroup v1, and this machine's Docker Desktop
VM runs cgroup v1 — so `scripts/kind/up.sh` pins the node image to `v1.33.12`, the newest kind
release confirmed to boot here. Bump once Docker Desktop moves to cgroup v2. Separately, the
`google` provider block calls `Configure()` (and attempts Application Default Credentials)
whenever it's declared at all, even with zero resources referencing it — worked around with a
placeholder `access_token` in kind mode that is never sent anywhere.

**D18-2. Config Sync OSS + Gatekeeper OSS stand in for the Fleet-installed, Policy-Controller
GKE path — genuinely, not just nominally.** Both are the same upstream projects Google ships
through Fleet (`kpt.dev/configsync` v1.24.1, `open-policy-agent/gatekeeper` v3.22.2 — Policy
Controller *is* Gatekeeper under a different install path). The only OSS-specific step: OSS
Config Sync needs an explicit `CLUSTER_NAME` env var on `reconciler-manager` (Fleet sets this
automatically from the membership name) — set to `runtime-<env>`, which is what makes
ADR-0017's `configsync.gke.io/cluster-name-selector` scoping work. **Verified live:** with both
dev and prod payload manifests present in the synced tree, the dev kind cluster applied only
`search-a`'s dev version — the selector correctly excluded prod's.

**D18-3. Exact-KSA constraint (`K8sTenantUnitKsa`), additive to `deny-default-sa`.** A pod in a
tenant-labeled namespace must run as one of that tenant's **unit KSAs** — not merely a named,
non-default SA. The allowlist is read via Gatekeeper's referential-data sync
(`gitops/cluster/gatekeeper-sync.yaml` syncs `Namespace` into OPA's inventory) from the
namespace's `unit-ksas` annotation, written by `tenant-namespace` v0.11.0 — Terraform-owned, so
a tenant's namespaced `edit` role cannot tamper with its own allowlist. **Fails closed**: if the
Namespace isn't in Gatekeeper's inventory (sync Config missing or broken), the constraint denies
rather than admitting blind. This is the enforcement ADR-0016 D16-3 needs before Temporal
workers exist: a worker pod must be provably the unit's own identity, not merely "not default".

**D18-4. What this closes vs. what it doesn't.** Closed: cluster-mode pluggability, live
namespace isolation (netpol/quota/RBAC/KSA), live Config Sync reconciliation and pruning, live
Gatekeeper admission enforcement (both constraints), per-environment payload selector scoping.
**Still not verified anywhere:** the GKE/Fleet-specific half of each of these (Connect Gateway
host format, Fleet membership naming, Policy Controller's own install path) — kind proves the
*logic*; Connect Gateway is now a comparatively narrow transport-and-naming question, tracked in
`VERIFICATION.md`.

## Live verification (2026-07-07, this machine)

1. `terraform apply -var cluster_mode=kind`: 8 resources created — namespace `abf`, both
   NetworkPolicies, quota, limit range, RBAC, and the `search-a` KSA — against a kind cluster,
   zero GCP credentials.
2. Config Sync OSS, pointed at this **private** repo via a fine-grained read-only PAT (a
   `git-creds` Secret — the OSS stand-in for ADR-0012 D12-4's Secret-Manager token), synced
   `gitops/cluster/` (both constraints, the inventory Config, the `platform-system` namespace)
   and `gitops/payload/dev/abf/search-a.yaml` — **not** the prod manifest, confirming selector
   scoping.
3. Gatekeeper admission, tested directly: a pod with `serviceAccountName: default` — denied by
   both constraints. A pod with a real, named, but non-unit SA (`intruder`, created for the
   test) — denied by `K8sTenantUnitKsa` specifically, proving it does strictly more than
   `deny-default-sa` alone. A pod as `search-a` (the unit's actual KSA) — admitted.
4. Prune: opted `search-a` out in the registry, re-rendered, pushed — Config Sync deleted the
   live Deployment+Service on its next reconcile. Reverted; the objects came back. This is the
   mechanism M4's offboard pipeline and M3's demo offboard both depend on (VERIFICATION #6).

## Consequences

- `docs/VERIFICATION.md` gains a verified-table entry (row 6, payload half) and a new
  unverified row for the Fleet/Connect-Gateway-specific seam this doesn't cover.
- The acceptance-test demo (M3) can now assume a working namespace + delivery + policy
  substrate; it only has to add Temporal and the agent workload on top.
- `scripts/kind/up.sh` / `down.sh` are the repeatable path to this environment for anyone
  (including future-Aida after another laptop restart) — step-by-step in
  [`docs/runbooks/local-kind-plane.md`](../runbooks/local-kind-plane.md).
