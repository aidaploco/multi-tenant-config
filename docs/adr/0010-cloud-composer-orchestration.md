# ADR-0010: Cloud Composer orchestration plane

- **Status:** Accepted — scope amended by ADR-0016: Composer is the *scheduled-batch* plane only
  and is **parked** (the runtime root gates it behind `composer_enabled`, default `false`) until
  a data-pipeline tenant arrives. Temporal owns agentic/event-driven orchestration.
- **Date:** 2026-06-30
- **Builds on:** ADR-0001 D13/D14 (shared compute + the shared-Airflow trust zone), ADR-0008 (network), ADR-0009 (cluster). Milestone part 3b.

---

## Context

The shared runtime plane needs orchestration — managed Airflow — where tenant data pipelines are
scheduled. D13 chose **one shared Composer per environment** (not one per tenant) to avoid the
~$100k/month of idle control-plane cost that per-tenant Composer would incur.

## Decisions

**D-C1. One private Composer environment per `runtime-<env>`.** On the shared VPC, private
endpoint (no public IPs), backed by an OPA rule.

**D-C2. Its own least-privilege service account** (`composer.worker`), distinct from the CI SAs
and from tenant agent SAs.

**D-C3. Tenant isolation inside shared Airflow is operational, layered on later.** Per-tenant DAG
folders, Airflow RBAC, pools/quotas, and — critically — **`KubernetesPodOperator` running as the
tenant's own Workload-Identity SA** so a task can only touch its own tenant's data (D13). The
module stands up the *environment + identity*; this per-tenant config comes when tenants actually
run pipelines.

**D-C4. The shared-Airflow trust zone is accepted for non-`restricted` tenants** (D13/D14
residual risk, restated): the metadata DB, scheduler, and webserver are a shared trust zone — a
hostile/buggy DAG can degrade *scheduling* for everyone, but cannot read another tenant's data
(per-task WI SA). `restricted` tenants get dedicated compute and never share this.

> **Amended by ADR-0015.** "Cannot read another tenant's data" holds only if isolation is
> *enforced* at the Airflow/K8s layer (no shared `default` SA, per-tenant connections). ADR-0015
> makes it enforced rather than assumed.

## Honesty

This is the **least-verified** module. Composer networking (the three private CIDR blocks) and the
pinned `image_version` are apply-sensitive — the mocked tests prove wiring, not a live build.
Expect tuning on the first real apply. The CIDRs are allocated disjoint from the VPC, GKE, and each
other in the runtime root's locals.

## Consequences

- The shared compute plane is now structurally complete (cluster + orchestration); what remains is
  the part-4 reconciliation loop that makes it *safe for multiple tenants*.
- Per-tenant DAG isolation (D-C3) and the runaway-DAG controls are explicitly outstanding, not
  assumed.
