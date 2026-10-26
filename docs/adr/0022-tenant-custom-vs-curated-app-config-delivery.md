# ADR-0022: Tenant-custom vs. curated pack delivery — a trust-tier split, not a maturity ladder

- **Status:** Accepted
- **Date:** 2026-07-11
- **Builds on:** ADR-0021 (`manifest_ref`/`packs_ref`), ADR-0018 (exact-KSA / namespace
  isolation), ADR-0020 (`secret_ref`).
- **Coordinated with:** `agent-chassis`'s own D20 (commit `593c8af`) — that record and this
  one describe the same decision from each repo's side; reference both together.

---

## Context

ADR-0021 built `manifest_ref`/`packs_ref` to unblock the D18 kind-cluster gate, and flagged its
own gap plainly (D21-4): ConfigMap-delivered content is not GitOps-tracked, and — raised
independently by `agent-chassis` once a second real pack was in view — Python pack code
delivered this way bypasses code review, tests, and any build-time supply-chain check, unlike
an image that goes through CI.

The question wasn't "is ConfigMap delivery good or bad" — it's **whose code is it**. A pack
`agent-chassis`'s own team writes, tests, and ships is a different trust category from a
pack a *tenant* writes for their own bespoke tool. Collapsing those into one mechanism, or one
migration path from "temporary" to "permanent," undersells the real distinction.

## Decision

**D22-1. Two permanent mechanisms, split by trust tier, not by maturity.**
- **Curated, first-party packs** (`agent-chassis`'s own): bake into the image, ship via an
  ordinary version bump. This needs **zero new platform capability** — it's the identical path
  already run twice this week (`cs-agent` 0.2.0→0.2.1, `agent-chassis` 0.1.0→0.1.1). Their
  own CI (tests, lint, the import-linter contract) is the review/supply-chain gate, because the
  code lives somewhere that CI actually touches.
- **Tenant-custom, bespoke packs**: `packs_ref`/ConfigMap stays the permanent delivery
  mechanism — **not** a bootstrap convenience superseded once things mature. Baking a tenant's
  own code into a *shared* chassis image would co-mingle one tenant's code into an artifact
  every other tenant's rollout depends on — a real multi-tenancy problem this platform exists
  specifically to avoid, and a materially bigger commitment (per-tenant image builds) than
  anything decided here.

**D22-2. Role manifests get a real, GitOps-tracked home. Built 2026-07-11**, triggered by
exactly the case this ADR named — Lana replacing the throwaway skeleton, a recurring role
rather than a one-time gate fixture. `config/<tenant>/<ref>/manifest.yaml` +
`config/<tenant>/<ref>/packs/*.py`, committed to this repo (**keyed by the `manifest_ref`/
`packs_ref` value, not the unit name** — a refinement made during implementation: two units
sharing one ref, the normal case of an API and a worker loading the same role, collapse into
one directory and one rendered ConfigMap instead of duplicated content under two unit-named
paths). `scripts/render-payload.rb` reads that path and renders a real ConfigMap into
`gitops/payload/`, closing ADR-0021 D21-4 the same way every other generated artifact already
works — Config Sync applies it, prune-on-removal applies to it too.

**A real bug, caught live, not designed around in advance:** `config/` was first placed at
`gitops/config/` — inside the tree Config Sync's `RootSync` recursively scans. Config Sync
tried to parse a role manifest (no `apiVersion`/`kind`, it's application config, not a
Kubernetes object) as a K8s resource and rejected it (`KNV2001`). Moved to a top-level
`config/` directory instead — a **source** the renderer reads, exactly like `tenants/` already
is, never synced directly; only the rendered *output* lives under `gitops/payload/`. Worth
naming plainly: this wasn't caught by review, it was caught by watching the actual reconciler
logs after the first deploy attempt silently stalled.

Cross-repo automation to keep this path in sync with the workload repo is **not** part of this
decision — a human commits the file over, the same "don't build ahead of scale" discipline as
everything else here (ADR-0004).

**D22-3. Manifests are unreviewed business logic today, and that's stated plainly, not
implied.** A manifest controls guardrail thresholds and `approval_required_tools` — real
authority, not inert data. Neither manifests nor packs go through any review today (both are
currently raw `kubectl create configmap`, no gate). *(Narrowed by D22-2's own build, same day:
content under `config/<tenant>/` now lands via PR — reviewed by CODEOWNERS' platform-team
default like any repo change. The no-review claim still holds for the D22-1 tenant-custom
path (direct `kubectl` ConfigMaps), which is exactly where it matters most.)*

> **The same principle recurred and was headed off before code existed (joint review,
> 2026-07-20).** The chassis's D24 (SB-2 — scoped memory retrieval) proposed delivering
> `MEMORY_SCOPE_GRANTS` — *authorization policy*, who may read whose memory — via the
> ADR-0020 D20-3 Secret ride. Correctly rejected: a human-created Secret is exactly this
> ADR's unreviewed-authority shape, and D22-3's fix (a reviewable, GitOps-tracked path) is the
> right transplant. Registry-field home + reasoning: `docs/deployment-contract.md`. Nothing
> built yet — no tenant needs it (default entitlement requires no grants config) — same
> ADR-0004 discipline as everything else deferred in this repo. Whatever review mechanism eventually gets
built (D22-2's GitOps path is a prerequisite — code review needs something to review) should
cover both artifact types from day one, not treat YAML as pre-cleared because it isn't Python.

**D22-4. The honest accounting of what "leans entirely on your isolation" currently means.**
`agent-chassis`'s D20 correctly identifies that `PACKS_DIR` code runs unsandboxed, with
full worker-process privileges — same filesystem, same env vars (including that unit's
secrets), same network reach as the worker itself. What this platform's isolation **actually**
enforces today, checked directly rather than asserted from memory:
- **Enforced:** the namespace boundary (default-deny-ingress + same-namespace-allow
  NetworkPolicy), the exact-KSA constraint (a pod can only run as its own unit's identity,
  ADR-0018), and whatever IAM roles that unit's Workload Identity SA was explicitly granted
  (`agent-identity`'s `iam_roles` override).
- **NOT enforced, confirmed by reading the module source just now:** egress. Both tenant-
  namespace NetworkPolicies set `policy_types = ["Ingress"]` only — Kubernetes leaves egress
  completely unrestricted unless a policy explicitly says otherwise, and none here does.
  Concretely: pack code (tenant-custom or otherwise) can currently make outbound calls to
  anywhere, including exfiltrating its own pod's secrets to an external endpoint. This isn't
  new *because* of packs — it was already true of every unit — but it's materially more
  relevant once "arbitrary tenant-authored code runs in this process" is a designed-in,
  permanent case rather than a hypothetical.

## Consequences

- `agent-chassis`'s D20 and this ADR should be read together — neither is complete alone.
- **D22-4's egress gap: DONE, live-verified, 2026-07-11** (same day as this ADR — not deferred
  after all). `tenant-namespace` v0.12.0: default-deny egress + an explicit allow-list (DNS,
  same-namespace, `platform-system`, external-internet-minus-private-ranges), plus
  `extra_egress_cidrs` as a narrow, kind-mode-only escape hatch for `cs-agent`'s local
  Postgres/Redis dependency. Verified against the live cluster, not just planned: the private-
  range exceptions genuinely cover this cluster's real pod/service CIDRs (confirmed, not
  assumed); direct socket checks to all four legitimate endpoints (Postgres, Redis, Temporal,
  `api.openai.com`) succeeded; a direct attempt to reach the Kubernetes API server (a real
  sensitive target, previously reachable) was correctly blocked; both `cs-agent`'s and
  `agent-chassis`'s pod-kill-and-resume demos still pass end-to-end post-change. See
  `docs/VERIFICATION.md` for the full evidence log.
- `agent-chassis`'s tracked follow-up (surfacing pack provenance — builtin / entry-point /
  `PACKS_DIR` — in `/v1/self` and audit output) is entirely application-side; no platform
  action needed, but it would pair naturally with D22-2's GitOps path once both exist: an
  auditor could cross-reference "this pack came from `PACKS_DIR`" against an actual git-tracked
  commit instead of an untraceable `kubectl` action.
