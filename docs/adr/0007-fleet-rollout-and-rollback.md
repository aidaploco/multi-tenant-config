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

> **Amended by [ADR-0011].** This ADR originally described canarying a module by bumping *one
> tenant's* per-layer version pin — which never worked (Terraform forbids a dynamic `?ref=`) and
> isn't wanted (module versions are fleet-wide by design). The corrected process is below: the
> **canary is the `dev` environment**, not a single tenant.

[ADR-0011]: 0011-fleet-wide-platform-versioning.md

### Module upgrades (a `multi-tenant-platform` bump, e.g. `gcs` v0.1.0 → v0.2.0)

Module versions are fleet-wide (one `VERSIONS.md`). The **environment** is the canary, not a tenant:

1. **Canary = dev.** Bump `VERSIONS.md` + the literal `?ref=` in one PR. PR → plan → OPA gate →
   apply **dev** (all dev tenants). **Soak.** dev is where a bad version is caught.
2. **Promote.** Approve `acc`, then `prod` — the dev→acc→prod gates (D9) are the soak boundaries.
3. **Rollback.** `git revert` the PR; the plan shows the downgrade; apply. Rollback follows the
   same dev→acc→prod path. (KMS/state-bearing modules: confirm the downgrade is reversible first.)

### Unit version rollouts (axis-2)

> **Amended by ADR-0026 (D26-4).** A prod `version` change now additionally requires a passing
> eval report (`evals/<tenant>/<unit>/<version>.yaml`) — CI-enforced. Rollback stays untaxed by
> construction: the rolled-back-to version's report already exists from its original promotion.

Per-unit `version` in the registry; same canary → promote → bulk shape, but it changes a unit's
*inputs*, not a module source ref (ADR-0004). Independent per-unit rollback is the generator
graduation.

### Guardrails (already in place)

- **Never float** — always a pinned ref (D7).
- **One variable per rollout PR** — a bump changes versions and nothing else, so the plan is
  readable and the revert is clean.
- **The destroy-threshold OPA rule** blocks a rollout whose plan would delete more than the
  threshold — a tripwire against a botched upgrade.

## What is per-tenant vs fleet-wide (ADR-0011)

- **Config rollback is per-tenant.** Reverting a tenant's YAML (flags, opt-ins, IAM overrides,
  which units) changes only that tenant's resources — the `for_each` engine isolates them. So
  "roll back one tenant" works today for *config*.
- **Module rollback is fleet-wide, by design.** All tenants share one module version; a bad bump
  rolls back for the whole environment — which is the intended "1 platform, no zoo" behavior, made
  safe by the dev gate. This is **not** a limitation awaiting a fix.
- **Per-tenant *module* rollback** (hold one tenant on an old version while others move) is the
  rare exception — the documented generator graduation (ADR-0004/0005 triggers), not a default.

Note: ~~state is shared per environment, so an apply is one operation over all of an env's
tenants (shared lock/failure domain, ADR-0005)~~ — **superseded by ADR-0014**: state is now
per-tenant via workspaces, so applies are per-tenant operations with isolated locks. The
per-tenant config-rollback conclusion above got *stronger*, not weaker.

## Consequences

- A repeatable, low-drama upgrade path exists before the fleet is big enough to make mistakes
  expensive.
- The rollout process and the shared-state limitation are written down together, so no one assumes
  per-tenant isolation we do not have.
