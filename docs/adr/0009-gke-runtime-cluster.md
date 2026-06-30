# ADR-0009: GKE runtime cluster

- **Status:** Accepted
- **Date:** 2026-06-30
- **Builds on:** ADR-0001 D13 (shared compute), ADR-0008 (the network it runs on). Milestone part 3a.

---

## Context

The shared runtime plane needs a Kubernetes cluster: where tenant workloads (app-units) run as
their own Workload-Identity SAs, and where Config Sync reconciles per-tenant namespaces (part 4).
For a 3-engineer team, *how much cluster we operate* is the deciding constraint.

## Decisions

**D-G1. Autopilot, not Standard.** Google manages nodes, scaling, and node security; we don't run
a node fleet. One regional Autopilot cluster per `runtime-<env>`. Buys us out of the single
largest GKE ops burden — the right trade at our headcount.

**D-G2. Private nodes.** Nodes have no public IPs; egress is via the shared-vpc Cloud NAT only
(ADR-0008). Backed by an OPA rule (clusters must enable private nodes).

**D-G3. Control plane: authorized-networks, not fully private endpoint.** `enable_private_endpoint
= false` with `master_authorized_networks` defaulting to **empty** (no external reach). This is a
*deliberate, documented* relaxation from a fully-private endpoint: a private endpoint needs a
bastion or proxy for any `kubectl`, which is real ops for a small team. Authorized-networks (admin
via IAP, plus an explicit CIDR if ever needed) is the secure-enough default. **Revisit toward a
fully-private endpoint if compliance requires it** — it's a config change, not a redesign.

**D-G4. Workload Identity on.** The cluster's WI pool is `<runtime-project>.svc.id.goog` — exactly
what the tenant **agent-unit** SAs bind to (ADR-0002). This is the keyless bridge that lets a pod
act as the tenant's identity.

**D-G5. REGULAR release channel.** Auto-upgrades on the balanced track — security patches without
the bleeding edge, no manual upgrade toil.

## The boundary (again, because it matters)

This is the cluster only. **Per-tenant namespaces, default-deny `NetworkPolicy`, ResourceQuota,
and Policy Controller constraints are Config Sync's job (part 4).** Autopilot uses Dataplane V2, so
`NetworkPolicy` is supported natively — but it isn't *applied* until part 4. **Do not run two
tenants' workloads on this cluster before part 4 lands.**

## Consequences

- The shared cluster exists and is private + Workload-Identity-enabled; agent-unit bindings now
  have a real pool to target.
- Verified as *wiring* (mocked tests: autopilot, private nodes, WI pool), **not** as a live healthy
  cluster — that needs a real apply against the bootstrapped org.
- Control-plane access posture (D-G3) is the one consciously-relaxed knob; it's flagged for
  revisit, not forgotten.
