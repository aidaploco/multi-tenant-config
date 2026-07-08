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

### M3 — Temporal + agent integration + the demo — **infra + real worker DONE 2026-07-08, only the scripted demo remains**
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

**Real agent workload delivered + live-verified 2026-07-08 (ADR-0020):** `customer-service-agent`
landed real Temporal integration (`durable/worker.py`) — coordinated via a Claude Code session
in that repo, gathering its actual shape (one image, two roles: HTTP API + headless worker,
shared task queue, real app secrets) directly rather than guessed. Extended the registry/renderer
for it: `command` override (one image, two roles, no second Dockerfile), `port`/`expose_port`
(the worker renders no Service), `secret_ref` + an always-optional `envFrom` (a human pre-creates
the k8s Secret — never the registry — mirroring `git-creds`; the D16-5 codec key rides in the
same Secret as `TEMPORAL_PAYLOAD_CODEC_KEY`, its shape decided by the real worker's SDK config,
not guessed). Registry: `abf/dev` gained `cs-agent-api` (port 8000) and `cs-agent-worker`
(headless), both `task_queue: cs-agent`, both `secret_ref: cs-agent-secrets`.

**Live-verified, not just deployed:** both pods `Running`, 0 restarts once the human-created
Secret existed (the 5 restarts beforehand were `openai_api_key: Field required` — correct
fail-fast behavior, not a platform bug); each pod runs as its own KSA (`cs-agent-api`/
`cs-agent-worker`, admitted by the exact-KSA constraint, ADR-0018); the API's logs show a real
Postgres connection and RAG knowledge ingestion via `host.docker.internal` (confirming the local
Docker-network translation was correct); and — the definitive check — **Temporal's own server
shows two active pollers** (`workflow` and `activity` task types) identified by the worker pod's
name on the `cs-agent` queue. This is genuine end-to-end connectivity, server-side confirmed,
not an app-side log claim taken on faith.

**Still open:**
- The scripted end-to-end demo: **pod-kill-and-resume** (kill the worker pod mid-conversation,
  confirm the workflow resumes — now buildable, a real worker exists) and **demo offboard**
  (remove YAML → renderer prunes payload → Config Sync prunes → Terraform removes namespace —
  payload before namespace, always; the prune mechanism itself is already verified, M2).
- Deterministic workflow shape refinement (continue-as-new to bound event history, update
  handlers over signal+poll) — application-side, tracked for sequencing only.

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
**Secret Manager + the Secrets Store CSI Driver's GCP provider** (replaces the local plain-Secret
pattern, ADR-0020 D20-5 — the direct analogue of an Azure Key Vault CSI setup); **stateful-backend module per the ADR**; **temporal-namespace
module (Temporal Cloud) + per-tenant KMS-backed codec keys**; notification channels + billing
budgets firing; Config Sync token → keyless (ADR-0012 D12-4).

## Event-gated
LLM gateway (2nd LLM workload/tenant; interim cap = billing budgets). PR change detection
(~10 tenants; matrix cap 256 at 80). platform-modules repo governance (CODEOWNERS, no
direct-to-main, SHA pins or release automation).

## Won't-now (tracked in ADRs)
VPC-SC; per-env appliers; ingestion/BigQuery/compute layer modules; data-unit/app-unit
archetypes; per-tenant RepoSync; self-hosted Temporal or Airflow in any shared environment.
