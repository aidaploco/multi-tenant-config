# ADR-0002: Two-axis tenancy model and registry schema v2

- **Status:** Accepted
- **Date:** 2026-06-29
- **Deciders:** Platform team (Aida + 2 engineers)
- **Extends:** ADR-0001 (D3 tenant schema; refines the layer/unit language in D13/D14)
- **Supersedes:** none (the D3 *principle* — one data-driven YAML per tenant — is unchanged; only the schema *shape* grows)

---

## Context

ADR-0001 modelled a tenant as a **single stack of layers** (`storage`, `ingestion`,
`bigquery`, `compute`, `composer`) toggled by booleans, identical across all of the tenant's
environments. A review of the reference (Azure) platform surfaced a second axis the original
design lacks:

- **Axis 1 — layers:** the tenant's *substrate*. One of each, deployed in dependency order
  (onboarding → platform → storage → …). Singletons.
- **Axis 2 — scale units:** *workloads that sit on the substrate*. Zero-to-many per tenant,
  each an instance of a pluggable **archetype**, each independently deployable with **its own
  state, its own version pin, and its own feature flags**.

Without axis 2, a tenant cannot run (say) two search workloads on different versions, or roll
one workload forward in `dev` without touching the rest. The original boolean layer flags also
could not vary **per environment** — a tenant was "all dev, acc, prod the same."

This ADR adds axis 2 and the per-environment expressiveness, **without** reintroducing the
reference platform's failure modes (a code-generation engine, five synced repos). It is the
schema half; the deployment-engine half (Terragrunt Stacks) is staged separately.

---

## Decisions

### D2-1. Two axes, with a hard boundary between them

- **Layers (axis 1)** = the tenant **substrate**: `onboarding` (the project shell, baseline
  APIs, keyring, log bucket), `platform` (networking + identity baseline), and the data-plane
  layers. Exactly one of each per tenant per environment; ordered; dependency-chained.
- **Units (axis 2)** = **workloads on top of** the substrate. `0..N` per tenant per
  environment, each an instance of an archetype, each with isolated state and an independent
  version.

**The boundary rule:** if it is *infrastructure the tenant always has exactly one of*, it is a
layer. If it is *a workload the tenant may have several of, that versions on its own clock*, it
is a unit. **Failure mode avoided:** the reference platform blurred this line, so "add a
workload" and "change the foundation" were the same operation with the same blast radius.

### D2-2. Registry schema v2 (this ADR's concrete change)

`tenants/<slug>.yaml` grows from a flat object into a per-environment one:

- `environments` becomes a **map** (was a list). A tenant exists in exactly its keys.
- A `defaults:` block holds the baseline; each environment **shallow-merges** its overrides
  over it (override = restate the whole layer/unit entry — no deep field merge, so the result
  is always greppable).
- Each **layer** is now an object `{ opt_in, version, isolation? }` (was a bare bool).
- Each environment carries a **`units:`** map: `name -> { type, version, opt_in, feature_flags,
  overrides }`.
- `feature_flags:` maps exist at both the defaults and per-environment level.

The data-driven principle of D3 is intact: **adding a tenant, an environment, or a unit is
still data in one YAML file + one PR.** No new directories, no generator.

### D2-3. Two version namespaces — never conflate them

| Namespace | What it pins | Where it lives | Drift is… |
| --------- | ------------ | -------------- | --------- |
| **Unit version** | a workload/app *release* (`search-a: 1.4.0`) | per-unit, in the registry | **expected** — independence is the whole point of axis 2 |
| **Platform-module version** | an infra building block (`gcs@v0.3.0`) | central, in `VERSIONS.md` | a **smell** — converge it |

A `data-unit@1.4.0` still consumes `gcs@<platform-default>` internally. If per-unit pinning
leaks into per-unit *infra-module* pinning, we recreate the reference platform's "240
untestable combinations" through the back door. The schema keeps them in separate fields on
purpose.

### D2-4. Archetypes: which apply, and build order

| Archetype | Applies? | Shape on this platform |
| --------- | -------- | ---------------------- |
| `data-unit` | Yes — core | buckets/BQ/Pub/Sub/secrets in the tenant project (data plane). **Will absorb today's `storage`/`ingestion`/`bigquery` layers** — recorded here, migrated when the archetype is built. |
| `agent-unit` | Yes — built **first** | identity only: service account + Workload Identity binding + OAuth/API client + scoped IAM. Smallest blast radius; proves the unit machinery end-to-end. |
| `app-unit` | Yes — bounded by D13/D14 | a namespace + WI SA + DAG folder + quota on the **shared** runtime (dedicated only for `restricted`). Inherits D13 isolation controls; does not invent new ones. |

We build the **seam + one archetype** (`agent-unit`) first, then the others on the identical
contract — the same "build the second path when the case arrives" discipline as D14.

### D2-5. Mechanism = Terragrunt Stacks; still no homegrown generator

> **Amended by [ADR-0004].** The assumption below — that Terragrunt Stacks would generate units
> *dynamically* from the registry — was disproved by a spike: in Terragrunt 1.0.8 `unit` blocks
> are static and cannot loop over the registry. The decision is now: **deploy units inside the
> shared per-environment composition; the generator is a documented graduation path** (see
> ADR-0004 for triggers). The rejection of a homegrown generator *as the default* stands.

Per-unit isolated state (`…/<tenant>/<env>/<unit>/terraform.tfstate`) and independent
upgrade/rollback were intended to be delivered by **Terragrunt Stacks** (`unit`/`stack` blocks +
`terragrunt stack generate`) — data-driven generation by a **maintained tool**, not a bespoke
renderer we own. A homegrown recipe→files generator is **rejected as the default** — it is
exactly the reference platform's single largest source of complexity (ADR-0001 D1/D3). See
ADR-0004 for what the tooling actually supports and the agreed path.

[ADR-0004]: 0004-axis-2-deployment-stay-data-driven.md

### D2-6. Enforced now vs. recorded-but-inert

Schema v2 ships the **interface** ahead of the engine. To be honest about what actually does
something today:

| Capability | State today |
| ---------- | ----------- |
| Per-environment existence + layer `opt_in` + feature-flag plumbing | **Enforced** by the current `for_each` engine |
| Archetype validation (unknown unit type / missing version fails the plan) | **Enforced** (a precondition) |
| `restricted` → dedicated compute **and** composer guardrail | **Enforced** |
| Per-layer / per-unit **version pins** driving the module source ref | **Recorded, inert** — Terraform forbids a dynamic `?ref=`; deferred to the generator graduation (ADR-0004), not a near-term stage |
| **Unit provisioning** (creating the workload) | **Inert** — no archetype is implemented yet; the first (`agent-unit`) is a later stage |

### The archetype contract (the "template" that makes a new unit type repeatable)

Each archetype, when built, ships four things as one reviewable bundle:

1. a **Terragrunt unit template** (`include` + `generate`) — the deployable stub,
2. an **inputs/outputs** contract,
3. an **OPA ruleset** scoped to that archetype (mandatory for `agent-unit`: no overly-broad
   IAM, no external principals, scope allowlist — it touches identity/exposure),
4. a **registry-schema fragment** describing its `overrides`.

Adding a unit **instance** = one YAML stanza (data). Adding a unit **type** = one new archetype
bundle (a deliberate platform-team PR). Instances are data; types are reviewed code.

---

## Consequences

**Easier:** dev can run ahead of prod; a workload rolls forward without touching its
neighbours or the substrate; a new workload type is a contained, templated addition.

**Accepted cost:** the registry YAML is more verbose (per-environment blocks), and the version
matrix is larger — mitigated by D2-3's discipline (unit drift fine, infra drift converged) and
by keeping per-unit pins the exception-with-intent, not the default.

**Deferred (named so they aren't forgotten):**
- Terragrunt Stacks migration (the engine for D2-5/D2-6) — next stage.
- `data-unit` archetype + migration of `storage`/`ingestion`/`bigquery` off the layer flags.
- `agent-unit` archetype with its OPA ruleset.
- A CI check that per-unit infra-module versions resolve to `VERSIONS.md` (guards D2-3).
