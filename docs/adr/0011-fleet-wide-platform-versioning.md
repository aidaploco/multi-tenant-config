# ADR-0011: Fleet-wide platform versioning; remove per-tenant layer versions

- **Status:** Accepted
- **Date:** 2026-06-30
- **Amends:** ADR-0002 (D2-2/D2-6 — drops the per-layer version field), ADR-0004 & ADR-0005 (the "recorded but inert version pins" framing), ADR-0007 (the canary/rollback narrative).

---

## Context

Schema v2 (ADR-0002) gave every layer a per-tenant `version:` field, intended to allow per-tenant
module-version pinning (canary, hold-back). Two things turned out true:

1. **It never worked.** Terraform forbids a variable in a module `source` — the `?ref=<tag>` must
   be a static literal. In the single `for_each` root, every tenant is forced to share the same
   literal ref. So the per-layer `version:` could be *recorded* but could never *drive* the module
   version. Making it live needs the generator or per-tenant generated roots — both rejected /
   unavailable (ADR-0004/0005). The field was an inert seam.

2. **We don't actually want it.** The platform's coherent model is **one platform, many units and
   tenants** — not many platform versions. Per-tenant module-version divergence is a "zoo": N
   tenants on N versions is untestable and is exactly the drift `VERSIONS.md` exists to prevent.

So the field was both non-functional *and* contrary to the intended design. The ADRs read as if
it were a live (or soon-live) capability. ADRs must match the code.

## Decision

**D11-1. Platform-module versions are fleet-wide, single-sourced in `VERSIONS.md`.** Every tenant
runs the same module versions. The tenant registry carries **no** per-layer version; the field is
removed from the schema, the two example tenants, the engine, and the docs.

**D11-2. Module rollback is fleet-wide by design — not a limitation.** "gcs v2 is bad → all
tenants roll back together" is the intended behavior, made safe by the dev → acc → prod gates
(a bad bump is caught in dev, which is the canary environment). This replaces ADR-0007's
(non-functional) "canary one tenant by its version pin."

**D11-3. Config rollback remains per-tenant.** Reverting a tenant's YAML (flags, opt-ins, IAM
overrides, which units) changes only that tenant's resources — the `for_each` engine isolates them
at the resource level. So "roll back one tenant" works today for *config*; only *module versions*
are fleet-wide.

**D11-4. A unit's `version` is an app release, optional and archetype-specific.** It is the
workload's version (e.g. a container tag for a future app-unit), *not* a platform-module pin. An
identity-only `agent-unit` has none, so the previous "every unit must pin a version" guardrail is
**removed**. *(Partially reversed by ADR-0017 D17-5: once agent-units gained a delivery path,
`version` became the deployed image tag and is again REQUIRED for an opted-in agent-unit — the
renderer refuses without it. The "not a platform-module pin" half stands unchanged.)*

**D11-5. Per-tenant module divergence remains the generator graduation.** The one legitimate case
— a single tenant held back because a new module version breaks its specific workload — is rare,
an explicit exception, and the documented ADR-0004 graduation trigger. Not a default, not built.

## Consequences

- The registry is simpler and honest: layers are `{ opt_in, isolation? }`; module versions live in
  exactly one fleet-wide place.
- The rollback story is now accurate: config = per-tenant, modules = fleet-wide-by-design.
- Forward-pointers added at the amended ADR sections so none of them mislead.
