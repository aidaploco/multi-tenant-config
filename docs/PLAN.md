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

### ~~M3 — Temporal + agent integration + the demo~~ — DONE 2026-07-08
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

**The scripted demo — both halves live-verified 2026-07-08:**
- `scripts/demo/pod-kill-and-resume.sh`: a real conversation via the API (`update-with-start`
  against `ConversationWorkflow`, keyed by session ID) — kill the worker pod outright — a
  replacement pod re-registers as a poller — **the same workflow execution** (run ID unchanged)
  correctly recalls context from before the kill, through a genuine LLM call. Durability came
  entirely from the platform's own mechanisms (Deployment self-healing + Temporal's history),
  zero application-level recovery code. This is the project's acceptance test, passing for real.
- `scripts/demo/offboard.sh`: onboards a throwaway tenant (real commit, real `terraform apply`,
  real Config Sync sync), then offboards it and asserts the exact ordering ADR-0012/0017 depend
  on — payload pruned while the namespace still exists, **then** Terraform destroys the
  now-unreferenced namespace. All 5 checks passed on the first live run; the registry was left
  exactly as it started.

D16-5's codec landed too (`customer-service-agent`, `a1bd1d8`, image `0.2.1`): AES-256-GCM
wraps the pydantic data converter whenever `TEMPORAL_PAYLOAD_CODEC_KEY` is set — conversation
content is ciphertext in Temporal's history, not plaintext. No platform-side change needed
beyond bumping the deployed version; the delivery contract from ADR-0020 already covered it.
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

### Reference-platform review outcomes (2026-07-17)

A structured review of a mature external multi-tenant Kubernetes platform (architecture shared,
no code), used as a probe set against this one. Full scorecard in the session notes; what
survives into the plan:

- ~~**NetworkPolicy lockdown**~~ — **DONE 2026-07-17, live-verified** (ADR-0023): tenant `edit`
  could create allow-all egress policies or delete `default-deny-egress` outright. RBAC
  narrowed to view+operate (`tenant-namespace` v0.13.0), Gatekeeper backstop
  (platform-only NetworkPolicy writes), `platform-system` default-denied with one scoped
  pod+port exception (Temporal 7233).
- **Tenant-visible shared-cluster metrics** (M5-shaped, needs its own ADR): tenant-project
  telemetry is already IAM-isolated (stronger than the reference's label-proxy), but pod
  metrics on the shared cluster land where tenants can't see them at all. Steal the local half
  of their pattern: Prometheus + Grafana + a label-enforcing query proxy in `platform-system`,
  per-tenant Grafana orgs rendered from the registry — fully verifiable on kind. The ADR must
  argue why self-hosted *monitoring* in the shared plane is acceptable when self-hosted
  Temporal/Airflow are Won't-now.
- **Alert-termination OPA rule** (rides with M4's notification-channel work): every
  `google_monitoring_alert_policy` must reference ≥1 notification channel — same shape as the
  existing runbook-link rule, makes "alerts with no receiver" a plan failure.
- **Substrate CMEK** (thin, cloud-gated, register rows): `gke-autopilot` has no
  `database_encryption` / boot-disk key — etcd secrets and node disks ride Google-managed keys.
  Platform key from the runtime project; per-tenant CMEK is physically impossible on shared
  cluster disks (a stated limit of the shared-plane model, not a gap to fix).

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

**Day-one gate, not eventual hardening: the Config Sync token.** It's the platform's *only*
standing long-lived credential — ADR-0012 D12-4 says so explicitly ("the platform's first
long-lived secret"). Everything else here is keyless by design (WIF, Workload Identity); this
one git PAT is the exception, and its rotation today is a `rotation_days` *label* on a Secret
Manager entry — recorded, not enforced by anything. Do the D12-4 OCI + Workload Identity
migration (fully keyless) on activation day, before any tenant traffic; if that slips, enforced
short-lived rotation of the PAT is the minimum bar, not "eventually."

Everything else, unordered: org + billing + WIF; bootstrap state dance; repo vars (CI is
dormant until set); verify every `VERIFICATION.md` row (Connect Gateway, org policies,
Gatekeeper-on-GKE, drift run …); environment protection rules; **Artifact Registry module +
workload-repo WIF provider**; **Secret Manager + the Secrets Store CSI Driver's GCP provider**
(replaces the local plain-Secret pattern, ADR-0020 D20-5 — the direct analogue of an Azure Key
Vault CSI setup); **stateful-backend module per the ADR**; **temporal-namespace module
(Temporal Cloud) + per-tenant KMS-backed codec keys**; notification channels + billing budgets
firing.

**Same trip, different clock — the periodic-sweep items `VERSIONS.md` already flags but this
checklist didn't cross-reference:** the Composer `image_version` and the pinned GitHub Actions
versions age out and need manual bumps. Not activation-gated (they're not blocking, just
easy to forget) — but activation is a natural first checkpoint to actually do the sweep.

## Event-gated
LLM gateway (2nd LLM workload/tenant; interim cap = billing budgets). PR change detection
(~10 tenants; matrix cap 256 at 80). platform-modules repo governance (CODEOWNERS, no
direct-to-main, SHA pins or release automation).

**MCP tool authorization (gate: the first self-built MCP server).** No MCP servers exist in
this platform yet; `agent-unit` provisions identity only, with no concept of "which tools can
this agent invoke." When a real MCP server is built, the design lead (not yet an ADR — no
consumer to decide against): per-tool authorization as **registry-driven data** (an allow-list
of caller roles/identities per tool, analogous to how `units.*` already declares per-unit
config), enforced **deny-by-default** including on unknown tools — consistent with this
platform's existing fail-closed posture (the exact-KSA constraint, ADR-0018, already denies
when it can't positively identify the caller). Caller identity should ride on Workload Identity
— a GCP-issued ID token from the calling agent-unit's own service account — rather than
standing up a new external identity provider or API gateway just for this; the identity
primitive already exists (`agent-identity` module). Enforcement belongs in tested application
code (the MCP server itself, or a thin shared library), never hand-written into infra-as-code
templates — logic embedded in generated config is exactly the coupling ADR-0004 already argues
against.

Method detection (distinguishing a `tools/list` call from `tools/call`) is a buffered-body
JSON parse comparing the JSON-RPC `method` field — no routing trick, no separate endpoints.
**Known unhandled edge, explicitly not to be assumed solved:** JSON-RPC batching (an array of
request objects in one HTTP call) and SSE/streaming responses need their own decision and test
coverage when this is actually built — single-request buffered parsing does not automatically
extend to either.

**2026-07-12: the gate is expected to fire soon.** `ai-employees-core` has started design work
on a Second Brain memory substrate (retrieval API + MCP server). Re-read this whole entry
against that fact and it still holds — registry-driven per-tool allow-lists, deny-by-default,
Workload Identity caller identity, enforcement in tested application code, not IaC templates.
**Still not writing the ADR yet**: their MCP server design doesn't exist to decide against.
ADR-0004's own discipline — never build ahead of a real consumer — applies to the *decision
record* too, not just the code.

~~Egress restriction on tenant namespaces~~ — **DONE 2026-07-11**, same day it was flagged
(ADR-0022 D22-4). `tenant-namespace` v0.12.0: default-deny egress + an explicit allow-list (DNS,
same-namespace, `platform-system`, external-internet-minus-private-ranges) + a kind-mode-only
`extra_egress_cidrs` escape hatch. Live-verified: private-range exceptions confirmed to cover
this cluster's real CIDRs, all legitimate endpoints (Postgres/Redis/Temporal/OpenAI) still
reachable, the Kubernetes API server correctly blocked, both pod-kill-and-resume demos still
pass post-change. Per-unit-scoped allow-lists (rather than one namespace-wide baseline) remain
a future refinement if a workload ever needs a *narrower* allow-list than the shared default —
not built, no current need for it.

## Won't-now (tracked in ADRs)
VPC-SC; per-env appliers; ingestion/BigQuery/compute layer modules; data-unit/app-unit
archetypes; per-tenant RepoSync; self-hosted Temporal or Airflow in any shared environment.
