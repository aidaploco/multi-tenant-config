# Platform roadmap (v4 — mock-first, Temporal-oriented)

The platform is developed **without a live GCP organization** (deliberate: cost). The current
deliverable is a **reference implementation + decision record + local demo**, with an
activation checklist for when a real GCP org exists. The honest boundary between proven and
assumed lives in [`VERIFICATION.md`](VERIFICATION.md).

**The acceptance test for the whole effort** (see ADR-0016 and the integration brief): on one
laptop, zero cloud — onboard a tenant via YAML → namespace + isolation policies appear → the
agent workload deploys through the delivery path → start a conversation (a durable Temporal
workflow) → **kill the agent pod mid-conversation and watch the workflow resume** → Gatekeeper
rejects a non-compliant pod → clean tenant offboard.

Two disciplines keep mock-first honest:

1. **Verification register** — every seam only a live GCP can confirm is listed in
   `VERIFICATION.md` and presented as an assumption, never a fact.
2. **Keep cloud-only modules thin** — invest where local verification is real (kind, Config
   Sync OSS, Gatekeeper, Temporal dev server); defer cloud-only modules to activation.

## Milestones (strict dependency order)

### ~~M0 — Alignment~~ — DONE 2026-07-06
Composer parked behind `composer_enabled` (default false, unpark path kept tested); `abf` prod
composer opt-in flipped off; ADR-0016 **Accepted** with **D16-5** (payload codec: client-side
encryption of workflow payloads, local key in dev / per-tenant KMS keys at activation, workers
fail closed without it).

### ~~M1 — Workload delivery path (mock-first)~~ — DONE 2026-07-06
ADR-0017: the renderer is ADR-0004's generator graduation invoked surgically (payload only,
hard generated-vs-custom split); ownership amendment (Config Sync owns `gitops/payload/`,
workload kinds only); Artifact Registry + second WIF provider recorded but **deferred to
activation** (locally: kind local-registry, `localhost:5001`). `scripts/render-payload.rb`
stamps `gitops/payload/<env>/<tenant>/<unit>.yaml` (Deployment + Service, unit KSA,
`cluster-name-selector: runtime-<env>`); opted-in agent-units must pin `version` (the image
tag — it finally means something); restricted tenants refused. Golden-file tests + CI
re-render drift check in the guards job.

### ~~M2 — kind-based runtime plane~~ — DONE 2026-07-07
ADR-0018: `terraform/tenant-runtime` now takes `cluster_mode = kind | connectgateway` (same
resources either way — GCP data sources count-gated off, kubernetes provider points at the kind
context). `scripts/kind/up.sh`/`down.sh` stand up a kind cluster + local registry + Gatekeeper
OSS v3.22.2 + Config Sync OSS v1.24.1 (`CLUSTER_NAME=runtime-<env>`, the OSS half of ADR-0017's
selector scoping). tenant-namespace v0.11.0 adds a `unit-ksas` namespace annotation; the new
**exact-KSA** constraint (`K8sTenantUnitKsa`) reads it via Gatekeeper referential data and fails
closed — additive to `deny-default-sa`. **All of it live-verified**, not just reviewed: 8
namespace-isolation resources applied with zero GCP creds; Config Sync synced a private repo
via a token Secret and correctly scoped dev-only payload by cluster-name-selector; a
removed-unit re-render was pruned live and restored; Gatekeeper denied a default-SA pod and a
wrong-but-named-SA pod, admitted the correct unit KSA. Results in `docs/VERIFICATION.md`;
step-by-step to reproduce in `docs/runbooks/local-kind-plane.md`.

### M3 — Temporal + agent integration + the demo — **platform infra DONE 2026-07-07, rest blocked on the agent repo**
ADR-0019, scoped deliberately: `customer-service-agent` has no Temporal integration yet (checked
directly — no workflow/worker code, just a plain FastAPI/GraphQL app), so the worker, the D16-5
codec, and the live demo are **not built speculatively** against a consumer that doesn't exist.

Done and live-verified: **Temporal dev server** in-cluster (`gitops/cluster/temporal-dev-server.yaml`,
platform-system, `temporalio/temporal:1.7.2` + PVC persistence) — confirmed serving after
resolving a real ordering gotcha (Config Sync's apply-wait groups stalled on `search-a`'s
Deployment never reaching Ready because no image had ever been pushed to the local registry;
pushing a placeholder `nginx:alpine` under the `search-a` tags unblocked it, see the runbook).
**Per-tenant namespace demo script** (`scripts/temporal/create-namespaces.sh`, data-driven,
idempotent — NOT the `temporal-namespace` Terraform module, which correctly stays gated on
D16-4's real trigger) created and verified all 5 current tenant×environment namespaces.
**Payload wiring**: registry `units.*.task_queue` (optional, defaults to unit name);
`render-payload.rb` sets `TEMPORAL_ADDRESS`/`TEMPORAL_NAMESPACE`/`TEMPORAL_TASK_QUEUE` on every
agent-unit container — confirmed not just set but *reachable* (a live TCP connect from inside
the `search-a` pod to the frontend Service DNS, cross-namespace, succeeded).

**Still open, blocked on `customer-service-agent`:**
- The agent workload's actual Temporal worker (workflows/activities, task-queue polling) —
  app-side, tracked for sequencing only: openai-agents logic in ACTIVITIES, deterministic
  workflows, one conversation = one workflow with signals/updates, continue-as-new to bound
  event history.
- D16-5 codec key delivery (deferred until the worker's SDK config dictates the concrete shape —
  Secret vs ConfigMap, mount path — rather than guessing blind).
- The scripted end-to-end demo: **pod-kill-and-resume** and **demo offboard** (remove YAML →
  renderer prunes payload → Config Sync prunes → Terraform removes namespace — payload before
  namespace, always; the prune half is already verified, M2).

### M4 — Post-demo hardening (cloud-free)
- Lifecycle, cloud-grade: offboard `workflow_dispatch` pipeline (payload removal → targeted
  destroy in the tenant workspace → `workspace delete`; destroy BEFORE deleting YAML);
  orphan-workspace CI check; data-retention step; break-glass runbook.
- **Eval-gate promotion**: CI requires an eval-report artifact on PRs bumping a unit's prod
  `version`.
- Observability + budgets, code-complete/verify-later: notification channels wired into the
  observability module; `budget_usd` → `google_billing_budget`. Register-tagged.

### ADR backlog (parallel, any time)
Stateful backends (Cloud SQL/Memorystore need a VPC; ADR-0008 gives tenant projects none —
decide, supersede ADR-0008; **no module until activation**). Ingress/DNS story (demo uses
port-forward; gate: first external user of the chat API).

## Done
1. Correctness batch (2026-07-06): gitops ownership boundary + CI guard; registry guards;
   real OPA destroy override (policies v0.10.0 + opa-gate `allow_destroy`); shared-root drift;
   docs-vs-code fixes. 2. ADR-0016 drafted (Temporal orchestration strategy).

## Parked / scrapped (with reinstatement triggers)
- **Composer + the whole Airflow-isolation set** (per-tenant connections, Airflow RBAC,
  DAG-authorship ADR, Composer-SA IAM-starvation OPA rule): behind `composer_enabled` — the
  listed items are the **unpark checklist**, required before Composer ever serves two tenants.
- Dedicated-compute path for `restricted` tenants: flags remain opted out (registry honesty).

## Activation checklist (when a real GCP org exists)
Org + billing + WIF; bootstrap state dance; repo vars (CI is dormant until set); verify every
`VERIFICATION.md` row (Connect Gateway, org policies, Gatekeeper-on-GKE, drift run …);
environment protection rules; **Artifact Registry module + workload-repo WIF provider**;
**Secret Manager module**; **stateful-backend module per the ADR**; **temporal-namespace
module (Temporal Cloud) + per-tenant KMS-backed codec keys**; notification channels + billing
budgets firing; Config Sync token → keyless (ADR-0012 D12-4).

## Event-gated
LLM gateway (2nd LLM workload/tenant; interim cap = billing budgets). PR change detection
(~10 tenants; matrix cap 256 at 80). platform-modules repo governance (CODEOWNERS, no
direct-to-main, SHA pins or release automation).

## Won't-now (tracked in ADRs)
VPC-SC; per-env appliers; ingestion/BigQuery/compute layer modules; data-unit/app-unit
archetypes; per-tenant RepoSync; self-hosted Temporal or Airflow in any shared environment.
