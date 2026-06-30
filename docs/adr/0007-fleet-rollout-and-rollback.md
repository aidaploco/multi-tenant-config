# ADR-0007: Fleet rollout & rollback process

- **Status:** Accepted
- **Date:** 2026-06-30
- **Builds on:** ADR-0001 D7/D9 (pinning, environment promotion), ADR-0004/0005 (shared state).
- **Runbook:** [`docs/runbooks/fleet-rollout.md`](../runbooks/fleet-rollout.md)

---

## Context

We have the *mechanism* for controlled upgrades — every module is pinned (`VERSIONS.md` +
literal `?ref=`), and the registry already allows per-tenant/per-environment version divergence
(`abf` runs `search-a` 1.4.0 in dev, 1.3.0 in prod). What we lack is the *process*: how to move a
version across the fleet deliberately, with a canary and a rollback. This is the reference
platform's entire reason for existing; it needs to be written down **before tenant #4**, while the
fleet is small enough to get the muscle memory cheaply.

## Decision

### Module upgrades (a `platform-modules` bump, e.g. `gcs` v0.1.0 → v0.2.0)

A staged rollout, never a fleet-wide flip:

1. **Canary.** Bump the pin for **one tenant in dev only** (the registry supports per-tenant/
   per-env divergence). PR → plan → OPA gate → apply dev. **Soak.**
2. **Promote.** Roll the canary tenant through `acc` then `prod` — the dev→acc→prod gates (D9)
   *are* the soak boundaries.
3. **Bulk.** Once soaked, bump `VERSIONS.md` and the literal `?ref=` for everyone in **one PR**.
   The CI check that refs match `VERSIONS.md` keeps them honest.
4. **Rollback.** `git revert` the PR; the plan shows the downgrade; apply. (KMS/state-bearing
   modules: confirm the downgrade is actually reversible before relying on this.)

### Unit version rollouts (axis-2)

Per-unit `version` in the registry; same canary → promote → bulk shape, but it changes a unit's
*inputs*, not a module source ref (ADR-0004). Independent per-unit rollback is the generator
graduation.

### Guardrails (already in place)

- **Never float** — always a pinned ref (D7).
- **One variable per rollout PR** — a bump changes versions and nothing else, so the plan is
  readable and the revert is clean.
- **The destroy-threshold OPA rule** blocks a rollout whose plan would delete more than the
  threshold — a tripwire against a botched upgrade.

## The honest limitation (from ADR-0005)

State is **shared per environment**, not per tenant. So:

- A **canary is "change one tenant's pin,"** but the *apply* runs the whole environment's shared
  state — the blast-radius caveat from ADR-0005 applies.
- A **bulk rollback rolls back the whole environment**, not one tenant. True per-tenant rollback
  needs the generator graduation (ADR-0004/0005 triggers).

This limitation is acceptable at current scale and is itself one of the graduation triggers: when
you genuinely need to roll one tenant back independently, that is the signal to graduate.

## Consequences

- A repeatable, low-drama upgrade path exists before the fleet is big enough to make mistakes
  expensive.
- The rollout process and the shared-state limitation are written down together, so no one assumes
  per-tenant isolation we do not have.
