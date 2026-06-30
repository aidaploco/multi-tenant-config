# ADR-0005: Axis-1 deployment & state layout — one shared per-environment composition

- **Status:** Accepted
- **Date:** 2026-06-30
- **Supersedes:** ADR-0001 **D11** (the mandate for per-tenant Terragrunt-generated roots, each with its own state).
- **Amends:** ADR-0001 **D4** (precision of the "private by default" claim). Aligns with ADR-0004 (the axis-2 equivalent of this decision).

---

## Context

Two record-vs-reality gaps surfaced in review and need to become explicit decisions rather than
accidents of the MVP.

**1. The state layout drifted from D11.** ADR-0001 D11 decided: *"Use Terragrunt to generate one
isolated root per tenant per environment, each with its own provider/impersonation and its own
state file,"* specifically to bound blast radius (*"one tenant's bad YAML… fails only that
tenant's plan/apply, not the whole fleet"*). The implementation never did this. What exists is a
**single `for_each` root**: `terraform/tenants/` loops every tenant and writes **one state object
per environment** (`prefix=tenants/<env>`), **shared across all tenants**. So the per-tenant
isolation D11 promised does not exist, and the foundational ADR currently misleads a reader.

The ADR-0004 spike also established *why* D11-as-written is not achievable under our constraints:
data-driven per-tenant isolated state needs either a code generator or hand-written per-tenant
files — both rejected (ADR-0001 D1/D3) — and Terragrunt 1.0.8 cannot generate roots from the
registry dynamically. So this is the **axis-1 instance of the exact trade-off ADR-0004 settled
for axis-2.**

**2. "Private by default" over-claims what is enforced.** D4 asserts private-by-default as a
locked, day-zero property. Today only the **no-public-exposure** half is actually enforced (the
bootstrap org policies: deny external IPs, block default-network creation, restrict regions). The
**positive** private-connectivity path (a VPC with Private Google Access, PSC) and the **VPC-SC**
exfiltration perimeter are not built. The claim needs tightening to match reality.

## Decision

**1. Axis-1 layers deploy in one shared per-environment composition.**
One Terraform state per environment, shared across all tenants (the current `for_each` root is the
intended design, not a stopgap). The per-tenant **layer stack** (onboarding → platform → storage →
ingestion → units) exists as an **ordered dependency graph *inside* that single state** (Terraform's
module DAG via references), **not** as independently-stated roots. *(This ADR originally said
per-layer version pins "stay recorded but inert"; **ADR-0011 removed the per-layer version field
entirely** — module versions are fleet-wide in `VERSIONS.md`.)*

**2. Supersede D11's per-tenant-roots mandate.** Per-tenant / per-layer isolated state is **not** a
near-term goal; it is the same documented **generator graduation** as ADR-0004, governed by the
same triggers.

**3. Tighten the private-by-default claim (amends D4).** State it precisely:
> **No public exposure is enforced day-zero** (org policies). **Private connectivity (VPC + Private
> Google Access + PSC) and the VPC-SC perimeter are a deferred target**, delivered with the runtime
> milestone. Do not describe the platform as "fully private by default" until those land.

## Why this is acceptable (and what we accept)

- **Same logic as ADR-0004:** the only ways to get isolated per-tenant state are a generator or
  per-tenant files; both reintroduce the reference platform's failure mode at a scale (and
  headcount) we do not have.
- **The cost we accept is blast radius** — the very thing D11 wanted to avoid. With one shared
  state per environment, a single tenant's bad plan or apply error can fail **that environment's**
  apply for everyone. Mitigations that make this tolerable at current scale:
  - the **OPA gate + a plan on every PR** catch most bad config *before* it reaches apply;
  - **per-tenant guardrail preconditions** fail only the offending tenant *at plan time*;
  - **drift detection** runs read-only per environment.
  At single-digit tenants this is a real but non-binding cost. It becomes binding at scale — which
  is precisely a graduation trigger.

## Graduation

Identical triggers to ADR-0004. Move to generated per-tenant roots (the generator path, applied
surgically) when **any** of:

1. shared per-env state becomes a **recurring failure domain** (one tenant repeatedly blocks the
   environment's apply);
2. plan/apply time on the environment root grows operationally painful;
3. a tenant needs genuinely **independent per-layer version pinning** the shared composition cannot
   express;
4. headcount exists to own the generator and its generated-vs-custom discipline.

## Consequences

- The recorded design now matches the code; D11 no longer misleads a future engineer.
- The private-by-default claim is honest about what is enforced vs. targeted.
- We can build the **runtime milestone** (runtime-`<env>` projects + shared-VPC/PGA + GKE +
  Composer + Config Sync) on an accurate foundation — and that milestone is where D4's deferred
  half (private connectivity, VPC-SC) gets built.
- **Still open, by design:** blast-radius isolation for axis-1, independent per-layer/per-unit
  version pinning, and the **fleet rollout/rollback process** (its own ADR, due before tenant #4).
