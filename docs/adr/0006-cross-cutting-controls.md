# ADR-0006: Cross-cutting controls — observability baseline & rotation cadence

- **Status:** Accepted
- **Date:** 2026-06-30
- **Extends:** ADR-0001 (D6 CMEK, D8 policy). Names two *cross-cutting* controls that must be
  present on every relevant resource, not built once.

---

## Context

Two controls are easy to assume and easy to let rot, because they are not single resources — they
are properties that must hold *everywhere*, forever:

- **Observability.** The `observability` module exists and is wired per-bucket today. The risk
  (raised in review) is that it silently fails to become a *uniform* pattern as new layers land.
- **Rotation.** CMEK keys rotate; but rotation is a *runtime* control (a cadence), not a
  create-time fact, and it was never written down as a decision. Secrets do not exist yet but will.

## Decision

### Observability is a platform-shipped, uniform baseline

- **The platform ships observability; tenants do not opt in.** A tenant may disable a specific
  baseline alert or add their own, but **cannot remove the module invocation.**
- **Every data resource gets a matching `observability` invocation**, the same shape buckets use
  today (`bucket_observability` for_each `module.buckets`). When `pubsub`, `bigquery`, `compute`
  etc. are built, each **must** wire observability the same way — this is a build-time checklist
  item for every new layer/archetype, recorded here so it is a rule, not a habit.
- **Notification channels are per-tenant, passed in** — created once per tenant, never per resource.
- **Enforcement today:** the OPA gate requires every alert to link a runbook (added in
  `platform-modules` ≥ v0.3.0). The structural guarantee (composition always pairs a data resource
  with its observability) is the primary teeth. A stricter "every bucket has a matching dashboard"
  cross-resource OPA correlation is **deferred** as brittle; the structural pattern + runbook rule
  are sufficient now.

### Rotation cadence is non-negotiable, like CMEK-required

| Thing | Cadence | State |
| ----- | ------- | ----- |
| **CMEK keys** | **≤ 90 days**, native GCP rotation (no cron) | **Built + enforced** — `kms-tenant` sets `rotation_period` (90d default, min 1d validated); OPA requires it to be set. |
| **Secrets** (Secret Manager) | carry an explicit `rotation_days` + an owner | **N/A yet** — none exist (keyless, D5). The first will be the **Config Sync git credential** in the runtime milestone; it must ship with `rotation_days` (or be a short-lived token) from day one. |

Rotation is a runtime control: "created once" is never "done." Any future credential or key lands
with its rotation policy attached, or it does not land.

## Consequences

- Observability cannot silently become a gap: it is a named build-time requirement for every new
  layer, with an OPA backstop on the runbook link.
- The rotation expectation is explicit ahead of the first secret existing, so it cannot be
  forgotten when the runtime milestone introduces one.
- **Deferred:** the cross-resource "obs exists for every data resource" OPA correlation; secret
  rotation mechanics (with the runtime milestone).
