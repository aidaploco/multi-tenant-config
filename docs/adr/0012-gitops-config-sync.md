# ADR-0012: GitOps runtime plane (Config Sync)

- **Status:** Accepted
- **Date:** 2026-06-30
- **Builds on:** ADR-0001 D13 (shared runtime isolation controls), ADR-0009 (cluster), ADR-0006 (rotation). Milestone part 4 — the piece that makes the shared cluster safe for multiple tenants.

---

## Context

The shared GKE cluster (ADR-0009) has VPC-level controls but **no pod-level tenant isolation
yet** — until that exists, two tenants must not run on it. D13 lists the controls (default-deny
`NetworkPolicy` per namespace, `ResourceQuota`, namespace RBAC). The question is *how they get
applied and kept applied* — Terraform-applying K8s manifests drifts and ordering-breaks, which is
why the gap analysis called for a **GitOps reconciliation loop**.

## Decisions

**D12-1. Config Sync, installed via Fleet (`gke_hub`).** The GCP-native GitOps controller. It
continuously reconciles Kubernetes state from git — so the cluster's config is declarative,
self-healing, and auditable, not a pile of imperative `kubectl`.

**D12-2. Source = the `gitops/` directory of `multi-tenant-config`.** Honors the two-repo rule
(ADR-0001 D1) — a directory, not a third repo. Different lifecycle from Terraform (continuous
reconcile vs PR-gated apply), same repo.

**D12-3. Division of labor — the important one:**

> **Amended twice since.** ADR-0017 (D17-2): Config Sync additionally owns `gitops/payload/` —
> per-tenant *workload* kinds rendered from the registry (so "no per-tenant gitops files" below
> no longer holds; the files are generated, never hand-written, which is what the rule was
> protecting). ADR-0027 (D27-5): Config Sync also owns `gitops/platform/` — rendered
> platform-plane infra, where NetworkPolicy/ServiceAccount are admitted ONLY namespaced to
> `platform-system` (a namespace Terraform never manages, so exactly-one-controller still
> holds). The table's per-tenant-namespace row (Terraform's) is unchanged.

| Concern | Owner | Why |
| ------- | ----- | --- |
| **Cluster-wide, tenant-independent policy** (the isolation *contract*, Policy-Controller guardrails, shared platform workloads) | **Config Sync** (`gitops/`) | One declarative source, reconciled everywhere. |
| **Per-tenant namespace + its NetworkPolicy/Quota/RBAC + WI SA** | **Terraform tenant composition** (data-driven `for_each`) | Keeps tenant provisioning data-driven — no per-tenant gitops files, no generator (consistent with D3/ADR-0011). |

So the tenant-namespace **contract** (what a tenant namespace must look like; reference copy at
`docs/runtime/tenant-namespace-contract/` — moved OUT of the synced tree, since a concrete copy
inside `gitops/` meant Config Sync and Terraform both managed the same objects; the boundary is
now CI-enforced by `scripts/check-gitops-ownership.rb`) is stamped by Terraform, one per opted-in
tenant. Config Sync enforces, cluster-wide, that the contract holds (defense in depth) and
reconciles shared infra.

**D12-4. Credential flow (and the keyless tension, ADR-0001 D5).** Config Sync reads `gitops/`
with a **read-only token** stored in **Secret Manager** (`rotation_days` recorded — this is the
platform's *first* long-lived secret, exactly what ADR-0006 anticipated). The in-cluster
`git-creds` secret is populated from it operationally.
- **Documented hardening (preferred long-term):** package `gitops/` as an **OCI artifact in
  Artifact Registry** and have Config Sync pull it via **Workload Identity** (`gcpserviceaccount`)
  — fully keyless, no token. Deferred only because it adds a package-and-push CI step; the token
  path gets us reconciling sooner.

## Consequences

- Once Config Sync is installed and the per-tenant namespaces exist, the cluster is **multi-tenant
  safe** (default-deny per namespace) — lifting the "one tenant only" rule from ADR-0009.
- **Verified vs reviewed:** the `gitops/` manifests are validated (`kubectl --dry-run=client`); the
  Config Sync install (`gke_hub`) and the per-tenant namespace creation need a live cluster and are
  reviewed-only here.
- **Still outstanding:** the per-tenant namespace Terraform (couples to cluster access), Policy
  Controller constraint templates, and the OCI keyless hardening.
