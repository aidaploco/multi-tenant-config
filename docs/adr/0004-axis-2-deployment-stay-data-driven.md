# ADR-0004: Axis-2 unit deployment — stay data-driven; the generator is the documented graduation path

- **Status:** Accepted
- **Date:** 2026-06-29
- **Amends:** ADR-0002 D2-5 (mechanism) and D2-6 (what enforces version pins). Does not change the two-axis *model* — only how units are *deployed*.
- **Supersedes:** none

---

## Context

ADR-0002 D2-5 assumed **Terragrunt Stacks** would generate per-unit deployments **dynamically
from the registry** — giving each unit isolated state and an independent module-version pin,
data-driven, with no bespoke generator. A spike against the installed Terragrunt (**1.0.8**)
disproved that assumption:

- `unit` blocks are **static**. `for_each` over the registry fails (`There is no variable named
  "each"`), even under `--experiment-mode`.
- Static `unit` blocks *do* generate isolated per-unit directories — but you must **hand-write
  one block per tenant-unit**, which duplicates the registry.

So the only ways to get independent per-unit state **and** per-unit module-version pinning are:
**(a)** a code generator, or **(b)** hand-written per-unit files. Both are exactly what ADR-0001
(D1/D3) set out to avoid.

**Cross-check against the reference platform (Atlas, the production Azure system this design
learns from).** Atlas runs ~**27 domains × multiple unit types × layers × environments**, with a
**dedicated platform team**. At that scale, data-driven composition genuinely breaks and
hand-files are untenable — which is *why* Atlas built a generation engine. It contains the
synced-files failure mode with a strict **generated-vs-custom carve-out**: generated files are
regenerated and never hand-edited; custom files are hand-maintained and never regenerated, each
literally stamped:

> *"this is a custom variable file and is manually maintained. It will not be updated via
> changes coming from the atlas builder repo."*

That warning is **scar tissue** — it exists because regeneration clobbered hand edits and they
needed an escape hatch. ADR-0001's fear of the failure mode is therefore **validated in
production, not theoretical**.

## Decision

**Deploy axis-2 units as Terraform modules inside the shared per-environment composition** (the
existing `for_each` root). One state per environment; platform-module source versions pinned
centrally in `VERSIONS.md` (ADR-0002 D2-3). Per-unit *configuration* varies via inputs; per-unit
*module-source-version divergence* and *independent per-unit state* are **not** provided.

- **Reject Option 3 (hand-written per-unit files) outright.** It is the duplication cost of a
  generator with none of its automation. (Atlas's custom-file carve-out is a narrow *override*
  escape hatch, never the default deployment mechanism — do not mistake it for Option 3.)
- **Option 2 (a generator) is the documented GRADUATION path, not a "no."** Adopt it only when a
  trigger below fires, and adopt it surgically.

**Why this is right at our scale:** we have neither Atlas's scale nor its headcount. At a handful
of tenants, *"all units of a type in an environment share one state and one module version"* is
fewer moving parts and one source of truth — a **feature, not a bug**. The generator's cost (a
builder repo, the generated/custom discipline, a person to own it) buys an independence we do not
yet need.

**Precise statement of what is deferred** (narrower than "one version for everyone"): per-unit
config still varies freely via Terraform inputs. Only two things are deferred — varying a unit's
*module source ref* per unit within one environment, and giving each unit its own state file (and
thus independent rollback).

## Graduation triggers — implement Option 2 when ANY fire

1. A tenant must run **two or more units of the same archetype on different module-source
   versions in the same environment at once** (true divergent pinning the shared composition
   cannot express).
2. Shared per-env state becomes a **recurring failure domain** — one tenant's/unit's bad change
   repeatedly blocks others' applies, or plan/apply time on the env root grows operationally
   painful.
3. **Independent per-unit rollback** becomes a hard operational requirement.
4. **Headcount:** a platform engineer can *own* the generator and the generated-vs-custom
   discipline. Do not adopt at current headcount without this.

Rough scale anchor: think hard about this **well before** Atlas's 27-domain level — but not
before units-per-tenant routinely exceeds one **and** tenant count is in the dozens.

## How to graduate (pre-committed, so it is a planned step and not a redesign)

- **Generate only the slice that fans out** (axis-2 units). Keep axis-1 layers data-driven.
  Surgical generation, not Atlas's all-in.
- **Adopt Atlas's mitigation from day one:** a hard generated-vs-custom split — every generated
  file regenerated and never hand-edited (and stamped as such); custom overrides quarantined to a
  narrow, explicitly-flagged carve-out.
- The generator is a **pure function `registry → static unit blocks`** (we confirmed static
  blocks work). The registry stays the single source of truth; the generator owns no state of its
  own.

## Consequences

- Consistent with ADR-0001 D1/D3 — the simplest thing that works at our scale.
- The "Terragrunt Stacks stage" implied by ADR-0002 D2-6 is **cancelled as a near-term stage**;
  version-pin enforcement and per-unit state are deferred to graduation (above), not the next
  build.
- We already know exactly how the reference platform tamed the failure mode, so graduating later
  is a planned, bounded step — not a leap into the unknown.
