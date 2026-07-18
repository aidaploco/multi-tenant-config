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

### ~~M4 — Post-demo hardening (cloud-free)~~ — DONE 2026-07-18
ADR-0026, closing the lifecycle/promotion asymmetry (runtime plane hardened by ADR-0023/24/25,
lifecycle still script-grade). **Offboard, cloud-grade (D26-1):** three ordered steps —
`offboarding: true` flag PR (renderer renders the tenant EMPTY = the payload prune; CI matrices
freeze the tenant) → `offboard.yml` workflow_dispatch (preflight refuses if flag unmerged or
payload present; retention inventory fail-closed; per-env `plan -destroy` in the tenant's own
workspace, OPA `allow_destroy`, same approval gates as deploys; `workspace delete` fail-closes
on non-empty state; idempotent re-runs) → pipeline-opened removal PR, destroy always BEFORE
YAML deletion. Orphan-workspace drift check as independent backstop. **Data retention (D26-2)**
= evidence (terraform outputs + Cloud Asset Inventory artifact), not automated archival —
obligations are per-tenant facts, runbook-owned. **Break-glass (D26-3)** = the same procedure
by hand (`docs/runbooks/tenant-offboard.md`), never a second procedure. **Eval gate (D26-4):**
changed *effective* prod versions demand `evals/<tenant>/<unit>/<version>.yaml` with
`verdict: pass`; rollbacks/dev free by construction; 9-case test battery. **Grafana org prune
(D26-5, closes the ADR-0024 follow-on):** `provision-orgs.sh --prune`, live-verified. Local
halves live-verified 2026-07-18; credentialed halves = register row 17. The observability +
budgets bullet was closed earlier by ADR-0025 (D25-2/D25-3, register row 12).

### Reference-platform review outcomes (2026-07-17)

A structured review of a mature external multi-tenant Kubernetes platform (architecture shared,
no code), used as a probe set against this one. Full scorecard in the session notes; what
survives into the plan:

- ~~**NetworkPolicy lockdown**~~ — **DONE 2026-07-17, live-verified** (ADR-0023): tenant `edit`
  could create allow-all egress policies or delete `default-deny-egress` outright. RBAC
  narrowed to view+operate (`tenant-namespace` v0.13.0), Gatekeeper backstop
  (platform-only NetworkPolicy writes), `platform-system` default-denied with one scoped
  pod+port exception (Temporal 7233).
- ~~**Tenant-visible shared-cluster metrics**~~ — **local half DONE 2026-07-17, live-verified**
  (ADR-0024): Prometheus (kubelet-cAdvisor only, `emptyDir` — nothing precious on monitoring's
  disks, D24-1) + prom-label-proxy (`--error-on-replace` refusal verified) + Grafana
  (org-per-tenant, pinned datasource, viewer-403 asserted) in `platform-system`, each behind
  its own exact-dataflow NetworkPolicy (the D23-3 doctrine's first real exercise); tenant pods
  verified unable to reach any of it; `scripts/grafana/provision-orgs.sh` idempotent from the
  live tenant-labeled namespaces. Activation half = VERIFICATION.md row 15 (GMP swap, Terraform
  Grafana provider, per-tenant GCM datasource, Google auth). Not built, tracked in the ADR:
  app-level `/metrics` scraping (needs a consumer), dashboards-as-code, alert rules; the fourth
  item, offboard org pruning, closed 2026-07-18 by ADR-0026 D26-5 (`--prune`, live-verified).
  Original rationale kept below for the ADR's context:
  tenant-project
  telemetry is already IAM-isolated (stronger than the reference's label-proxy), but pod
  metrics on the shared cluster land where tenants can't see them at all. Steal the local half
  of their pattern: Prometheus + Grafana + a label-enforcing query proxy in `platform-system`,
  per-tenant Grafana orgs rendered from the registry — fully verifiable on kind. The ADR must
  argue why self-hosted *monitoring* in the shared plane is acceptable when self-hosted
  Temporal/Airflow are Won't-now.
  Concrete mechanics (from the review's second round, 2026-07-17; cloud-agnostic):
  `prom-label-proxy --label=namespace --enable-label-apis --error-on-replace` in front of
  Prometheus; one Grafana org per tenant; a provisioned datasource per org whose URL hardcodes
  `?namespace=<tenant>`; provisioning via the Terraform Grafana provider
  (`grafana_organization` + `grafana_data_source`), data-driven from the registry, with
  `ignore_changes` on org membership (it mutates outside Terraform — the ADR-0012 lesson).
  **Two hard decisions the reference gets wrong, to state in the ADR:** (1) the proxy trusts
  the caller-supplied `namespace` param, so workload-to-proxy reachability IS the tenant
  boundary — the reference leaves it open to every in-cluster pod ("ClusterIP, no ingress" is
  not a boundary); our `platform-system` default-deny (ADR-0023 D23-3) already closes it, and
  Grafana gets its own scoped ingress rule, never a namespace exemption. (2) Tenant Grafana
  users are never org Admin (OSS Grafana: datasource management is org-Admin-only), enforced
  by a verification-battery check ("datasource edit as tenant user → 403"), not by trust.
  At activation: add a per-org Google Cloud Monitoring datasource authenticating as the
  tenant's own GSA against the tenant's own project (register row).
- ~~**CI shape-check for fully-empty NetworkPolicy rules**~~ — **DONE 2026-07-17**
  (`scripts/check-netpol-shape.rb`, in the guards job; verified both directions — clean tree
  passes, a planted `egress: [{}]` fails naming file/policy/rule). Steals the reference's
  template-A *intent*, relocated to CI where it needs no exemption list: fail the PR if any
  NetworkPolicy under `gitops/**` (or in module fixtures) contains a fully-empty
  `ingress: [{}]` / `egress: [{}]` rule — the true allow-all shape. Guards the one writer the
  ADR-0023 admission constraint deliberately trusts: the platform itself. Deliberately does
  NOT copy the reference's "empty podSelector peer = unscoped" definition — same-namespace
  all-pods rules are intentional in our model (namespace = tenant boundary).
- ~~**Alert-termination OPA rule**~~ — **DONE 2026-07-17, code-complete** (ADR-0025 D25-2/D25-3):
  per-tenant owner-group email channel + `budget_usd` → real `google_billing_budget`
  (50/90/100% to the same channel) + the OPA rule (policies v0.14.0, plan-time-unknown channels
  accepted, 27/27 tests). This also closes M4's "notification channels + budgets" bullet at the
  code-complete/verify-later bar — delivery is register row 12.
- ~~**Substrate CMEK**~~ — **DONE 2026-07-17, code-complete** (ADR-0025 D25-1): `gke-autopilot`
  v0.14.0 requires `database_encryption` + boot-disk keys (fail-closed, no default); platform
  keys from a kms-tenant instance in the runtime project + service-agent grants in the runtime
  root. Cloud seams (grant ordering, Autopilot boot-disk field on a real create, quota project,
  keys-project placement) are register row 16.

**The review is closed**: 2 ideas were already ours (ownership split, keyless identity — both
finer-grained here), 2 adopted + live-verified (ADR-0023 netpol lockdown, ADR-0024 metrics
plane), 2 adopted code-complete (ADR-0025), 0 of its anti-patterns copied — and 3 of its holes
(netpol DELETE blindness, the open label-proxy, exemption-list-as-root-cause) are closed here
by construction.

### ADR backlog (parallel, any time)
~~Stateful backends~~ — **DONE 2026-07-18** (ADR-0028): per-tenant Cloud SQL/Memorystore in
tenant projects, **PSC connectivity — ADR-0008's no-tenant-VPC reaffirmed, not superseded**
(the entry below assumed the opposite; PSC removed the premise). Two new layers
(`postgres`/`redis`) at activation, delivery contract unchanged (`secret_ref` URLs —
host-run Docker blessed as the kind-mode half), decision-only per D28-5: no module until a
cloud exists to verify it against. One caveat recorded: classic Memorystore still wants a
VPC; the decision is Redis Cluster edition, and only a forced fallback to classic reopens
the VPC question. Ingress/DNS story (demo uses
port-forward; gate: first external user of the chat API) — **now the only backlog entry,
and it's gated**.

~~**Tenant trace plane**~~ — **DONE same day, 2026-07-18, live-verified** (ADR-0027):
per-tenant Phoenix instances (`15.11.1-nonroot`, ELv2 — license note in the ADR) rendered
into the new `gitops/platform/` tree, one per tenant per env; the instance NetworkPolicy is
the tenant boundary (D23-3's second exercise); `PHOENIX_COLLECTOR_ENDPOINT` delivered by the
renderer (`TEMPORAL_*` pattern); offboarding prunes the instance with the payload. Verified:
phoenix-abf Ready via Config Sync; reachable from abf's pods, blocked from a non-tenant
namespace; acceptance demo re-run green; **Phoenix's own API shows real spans** from the
demo's LLM traffic — zero app-side change needed. Activation half = register row 18; app-repo
compose cleanup owed (ADR consequences). Original flag text kept for context: Both real
workloads emit OTLP traces today, and the trace *backend* (Arize Phoenix + its Postgres) lives
in `customer-service-agent`'s docker-compose — an app repo maintaining shared observability
infrastructure, with `ai-employees-core` cross-wired to "the CS stack's Phoenix" via
host.docker.internal. Wrong side of the boundary: instrumentation (the OTel SDK, span
semantics) belongs in the apps; the collector/backend is platform infrastructure, exactly like
Prometheus/Grafana (ADR-0024) and the Temporal dev server (ADR-0019). Platform-side shape when
built: a collector in `platform-system` behind an exact-dataflow NetworkPolicy (D23-3
doctrine), endpoint delivered by the renderer as an env var (the `TEMPORAL_*` pattern),
apps keep their fail-soft no-endpoint posture. **Two hard decisions the ADR must face:**
(1) trace payloads carry plaintext conversation content — D16-5 encrypts exactly this in
Temporal's history, and a shared trace backend must not quietly reintroduce the leak
(span-content redaction, per-tenant isolation, or both); (2) Phoenix OSS's multi-tenant
authz is weak (projects are namespacing, not a boundary) — same problem class ADR-0024
solved for Grafana with orgs + a pinned datasource; the answer may be per-tenant Phoenix
instances or treating traces as platform-internal until a real isolation seam exists.
Local half fully kind-verifiable; coordinate the app-side handoff (moving Phoenix out of
the CS compose stack) with the app repos.

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
Vault CSI setup); **stateful-backend module per ADR-0028** (PSC + CMEK + the two layers, plus its register
rows: PSC producer/consumer config, Redis Cluster service-connection policy, per-tenant
egress exceptions, IAM DB authn vs interim passwords); **temporal-namespace module
(Temporal Cloud) + per-tenant KMS-backed codec keys**; notification channels + billing budgets
firing; **state disaster recovery** (ADR-0001's last still-open deferred item, surfaced by the
2026-07-18 consistency sweep): bucket versioning exists, a *tested restore procedure* does not
— write and rehearse one against the real state bucket.

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
