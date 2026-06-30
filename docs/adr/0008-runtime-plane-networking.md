# ADR-0008: Runtime plane networking

- **Status:** Accepted
- **Date:** 2026-06-30
- **Builds on:** ADR-0001 D4 (private by default), D13 (shared runtime plane). Delivers the
  private-connectivity half that ADR-0005 marked deferred.
- **Scope:** the network for the **shared runtime plane** only. Tenant *data*-plane projects have
  no VPC of their own — they hold storage/BigQuery/etc., whose isolation is the project boundary
  plus the (still-deferred) VPC-SC perimeter, not a private network.

---

## Context

D13 puts shared compute (GKE Autopilot + Cloud Composer) in `runtime-<env>` projects. That
compute needs a network, and D4 requires it to be **private from creation**. ADR-0001's
Consequences explicitly deferred the details to "a networking ADR before Phase 2." This is it.

## Decisions

**D-N1. One VPC per `runtime-<env>` project.** The shared runtime cluster runs on a single VPC
per environment. There is no per-tenant VPC — tenants are namespaces on the shared cluster (D13),
not separate networks.

**D-N2. Private by default, now actually built.** The `shared-vpc` module ships:
- **Private Google Access** on the subnet — pods reach Google APIs with no external IP.
- **No external IPs** (org policy already denies them; the module creates none).
- **Cloud NAT** as the *only* egress path — private nodes pull images etc. through NAT, nothing
  is directly internet-reachable.
- **Default-deny ingress** firewall (explicit + logged), `allow-internal` for intra-VPC traffic,
  and **admin access only via Google IAP** TCP forwarding (`35.235.240.0/20`) — never a public IP.
- **VPC-native** secondary ranges (pods, services) for GKE.
- **Flow logs** on the subnet.

**D-N3. Two layers of east-west control, by design.** The firewall governs VPC L3/L4; **pod-level
isolation between tenants is the Kubernetes default-deny `NetworkPolicy` per namespace** (D13),
applied via Config Sync in milestone part 4 — *not* this module. Stating it so the split is
deliberate: network module = perimeter + egress; GitOps = per-namespace deny.

**D-N4. VPC-SC perimeter stays deferred.** The exfiltration perimeter wraps the tenant *data*
projects, is operationally heavy, and can lock out CI if mis-sequenced (ADR-0001 Consequences).
It is dry-run-first, its own future work — the runtime VPC here is a prerequisite for compute, not
the data perimeter.

## Enforcement

The `shared-vpc` module is backed by two new OPA rules (platform-modules ≥ v0.4.0), so the
guarantees hold even for hand-written networking:
- no ingress **allow** rule may use source `0.0.0.0/0`;
- every subnetwork must have `private_ip_google_access = true`.

## Consequences

- D4's "private connectivity" half is real for the runtime plane (PGA + NAT + IAP-only + default
  deny), closing the honest gap ADR-0005 named. The data-plane perimeter (VPC-SC) remains the
  outstanding piece.
- Tenant east-west isolation depends on the part-4 `NetworkPolicy`; until Config Sync is in, the
  shared cluster has VPC-level controls but not per-namespace deny — do not run two tenants'
  workloads on it before part 4.
- The module is released and ready; the `runtime-<env>` root that consumes it is part 2.
