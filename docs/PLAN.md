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

### M0 — Alignment (small PR, do first)
- Park Composer: `composer_enabled` flag (default **false**) around the runtime root's composer
  module — code kept, nothing new may couple to it (ADR-0016 D16-1). Flip `abf` prod's
  `composer.opt_in` to false (registry must not claim what nothing provisions — helix
  precedent).
- ADR-0016: Proposed → **Accepted**; add **D16-5** — Temporal payload codec: workflow payloads
  (conversation content) are encrypted client-side via a custom Data Converter; local key in
  dev, per-tenant KMS-backed keys at activation; **workers fail closed without the codec**.

### M1 — Workload delivery path (mock-first)
- Delivery ADR: the renderer is ADR-0004's documented generator graduation; amends the gitops
  ownership contract (Config Sync owns per-tenant **app payload**; Terraform keeps all policy
  kinds — already CI-enforced by `scripts/check-gitops-ownership.rb`); records the
  workload-repo image/WIF trust design but **defers Artifact Registry + a second WIF provider
  to activation** (locally: kind's local-registry pattern).
- Renderer: a script in CI stamping per-(tenant, unit, environment) manifests from the
  registry into the synced payload dir, as reviewable committed diffs. Golden-file tests. The
  registry's `units.*.version` finally means something. No Helm, no operator, no RepoSync.

### M2 — kind-based runtime plane
- Provider pluggability for `terraform/tenant-runtime`: `cluster_mode = kind | connectgateway`,
  including making the `google_project` data source conditional (it requires GCP creds even to
  plan today).
- Config Sync **OSS** + Gatekeeper on kind, syncing this repo for real: cluster baseline,
  per-tenant namespaces (netpol/quota/RBAC/KSAs) applied by Terraform, reconciliation + prune
  verified live.
- Constraint upgrades, testable here: keep `deny-default-sa`; add the **exact-KSA** constraint
  (a pod in a tenant namespace must run as one of that tenant's unit KSAs) — now load-bearing
  for Temporal workers.

### M3 — Temporal + agent integration + the demo
- Temporal **dev server in-cluster** (`gitops/cluster/`, platform-system namespace — shared
  platform workload, permitted by the ownership guard), standing in for Temporal Cloud
  (ADR-0016 local/dev exception; same SDK code paths).
- Per-tenant Temporal namespaces created by the demo script (CLI), mirroring D16-3's mapping —
  the `temporal-namespace` Terraform module stays gated on Temporal Cloud (D16-4).
- The agent workload (built in its own repo, image in the local registry) declared as an
  `agent-unit` in tenant YAML; rendered by M1; deployed by Config Sync; worker connects to its
  task queue with the D16-5 codec active.
- The scripted end-to-end demo incl. **pod-kill-and-resume** and **demo offboard** (remove
  YAML → renderer prunes payload → Config Sync prunes → Terraform removes namespace — payload
  before namespace, always).
- App-side work (agent repo, tracked for sequencing only): openai-agents logic in ACTIVITIES,
  deterministic workflows, one conversation = one workflow with signals/updates,
  continue-as-new to bound event history.

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
