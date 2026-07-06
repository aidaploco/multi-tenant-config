# ADR-0013: Per-tenant runtime namespaces

- **Status:** Accepted
- **Date:** 2026-06-30
- **Builds on:** ADR-0012 D12-3 (Terraform owns per-tenant namespaces), ADR-0009 (cluster), ADR-0002 (agent-units). Closes the "cluster is not yet multi-tenant safe" gap.

---

## Context

The tenant-namespace template (now `docs/runtime/tenant-namespace-contract/`, kept outside the
Config-Sync-synced tree) defines the isolation *contract*, but nothing stamps it
per tenant yet — so the shared cluster still isn't safe for two tenants (ADR-0009). ADR-0012 D12-3
decided **Terraform** creates per-tenant namespaces (data-driven `for_each`), not per-tenant gitops
files. This ADR says how.

## Decisions

**D13-1. A dedicated root: `terraform/tenant-runtime/`.** Per-tenant namespace state is separate
from both the data-plane tenant root and the runtime-infra root. It depends on *both* (the cluster
must exist; the tenant GSAs must exist), so it applies after them.

**D13-2. Cluster access via Connect Gateway — keyless, IP-independent.** The cluster is private
(no external control-plane access). Rather than poke holes in `master_authorized_networks` for
ephemeral CI IPs, Terraform reaches the API through **Fleet Connect Gateway** (the cluster is
already Fleet-registered by `config-sync`), authenticating with the applier SA's short-lived token
(D5-keyless). The applier gets `roles/gkehub.gatewayAdmin`. **Operational prerequisite:** Connect
Gateway gives API *reachability*, but Kubernetes RBAC still applies — the applier also needs an
in-cluster ClusterRoleBinding (e.g. via a Google-group mapping) to create namespaces. That binding
is a one-time bootstrap step on the cluster, not Terraformed here.

**D13-3. What each tenant namespace gets** (the `tenant-namespace` module, mirroring the gitops
contract): the namespace, `default-deny-ingress` + `allow-same-namespace` NetworkPolicies,
`ResourceQuota` + `LimitRange`, namespace-scoped RBAC for the tenant's `owner_group`, and a
**Kubernetes SA per agent-unit annotated to that unit's GCP SA** — completing the Workload Identity
bridge whose GCP half the agent-unit already built.

**D13-4. Eligibility.** A namespace is created for each tenant whose env opts into **shared**
compute (`layers.compute.opt_in` and not `dedicated`). `restricted`/dedicated tenants don't share
the cluster (D14), so they get no shared namespace.

## Honesty — the verifiability floor

- **Verified (mocked):** the `tenant-namespace` module's wiring (namespace, default-deny, quota,
  the KSA→GSA annotation, RBAC) and the registry eligibility filtering.
- **Reviewed only:** the `kubernetes` provider over **Connect Gateway** — the endpoint URL format
  and live auth can only be confirmed against a real Fleet-registered cluster. This is the single
  most apply-sensitive seam in the platform; expect to confirm the Connect Gateway host on first
  real apply.

## Consequences

- Once applied, the shared cluster is **multi-tenant safe** — every tenant namespace is
  default-deny-isolated with its own quota and Workload Identity. The ADR-0009 "one tenant only"
  rule lifts.
- New cross-root dependency: `tenant-runtime` after `runtime` + `tenants`. Documented in CI.
- The keyless private-cluster access pattern (Connect Gateway) is now established for any future
  in-cluster Terraform.
