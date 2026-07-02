# ADR-0015: Shared-compute isolation model

- **Status:** Accepted
- **Date:** 2026-07-02
- **Amends:** ADR-0001 **D13/D14** (which framed the shared-Airflow risk as scheduling-DoS; it is also a **data-isolation** risk), and ADR-0010 (Composer).

---

## Context

We isolate the data plane per tenant, then route every non-`restricted` tenant through **one
shared Cloud Composer** per env. D13 called the residual risk "a hostile DAG can degrade
*scheduling*… it cannot read another tenant's data (per-task WI SA)." That understates it:

- The "can't read another tenant's data" guarantee holds **only if every task is a
  `KubernetesPodOperator` running as the tenant's WI SA** and connections/variables are
  per-tenant. **Airflow enforces neither.** A plain `PythonOperator` runs in-process on the shared
  worker → shared worker identity → cross-tenant reach. Shared connections leak config/secrets.

So shared Airflow is a **data-isolation** risk resting on *unenforced discipline*. Two things
compound it on the same trust boundary: **VPC-SC is deferred** (no exfil perimeter) and the
**applier is a fleet-wide god-credential** (compute/container/composer/gkehub/secretmanager admin
across every tenant folder).

The reference platform's answer is maximum isolation — **self-managed Airflow on per-domain
dedicated clusters** (own AKS + Postgres + Key Vault + Airflow namespace), ~27 domains × 3–4 envs =
*dozens of clusters to operate*. That is the cost of structural isolation, and it is exactly the
"run our own infra" burden D13 chose managed Composer to avoid.

## Options

| Option | Cost | Isolation | Ops |
| ------ | ---- | --------- | --- |
| **A. One shared Composer/env** (current) | $ | Low (shared control plane; fragile discipline) | Low (managed) |
| B. Composer per classification tier | $$ | Medium (blast radius per tier) | Low |
| C. Composer per tenant | $$$$ (~$100k/mo @ 80×3 — D15-rejected) | High | Low |
| D. Self-managed per-tenant Airflow on shared GKE (own db/SA/secrets/namespace) — the reference platform's model | $ (compute on existing cluster) | High (structural) | **High** (we run Airflow) |

## Decision

**Keep A, but make isolation *enforced*, not *assumed*, and close the compounding holes.**

1. **Built now — enforce named identities.** Enable **Policy Controller** (Gatekeeper) via
   Config Sync, and a constraint that **denies any pod in a tenant namespace from using the
   `default` service account** (`gitops/cluster/deny-default-sa.yaml`) — forcing workloads onto the
   per-tenant WI SA the `tenant-namespace` module creates. This turns D13's biggest fragile
   assumption into a hard admission control.
2. **Tracked — per-tenant Airflow isolation:** per-tenant connections/variables + Airflow RBAC (no
   shared connection store), and a stricter constraint requiring the *exact* tenant KSA (not merely
   "not default"). Operational config on the shared Composer.
3. **Tracked — pull VPC-SC forward:** the exfil backstop for the whole boundary (ADR-0005 deferred it).
4. **Tracked — scope the applier down:** per-env appliers at minimum, enabled naturally by
   ADR-0014's per-tenant/per-workspace provider config.

**Rejected:** C (cost). **Graduation to D** (self-managed per-tenant Airflow) — or B as a stepping
stone — when a `confidential` tenant needs structural isolation, or an incident proves the
enforced-discipline model insufficient.

## Consequences

- The single highest-leverage control (no shared default SA) ships now; the topology is unchanged.
- The remaining three are named with triggers, not forgotten — same trust boundary, three layers.
- We have accepted, in writing, that shared Composer is a *deliberate ops trade* whose price is
  **enforcing isolation at the Airflow/K8s layer**, since we don't get it from dedicated compute.
