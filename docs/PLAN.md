# Platform roadmap (mock-first)

The platform is developed **without a live GCP organization** (deliberate: cost). The current
deliverable is a **reference implementation + decision record + local demo**, with an
activation checklist for when a real GCP org exists. The honest boundary between proven and
assumed lives in [`VERIFICATION.md`](VERIFICATION.md).

Two disciplines keep mock-first honest:

1. **Verification register** — every seam only a live GCP can confirm is listed in
   `VERIFICATION.md` and presented as an assumption, never a fact.
2. **Keep cloud-only modules thin** — don't elaborate code whose core assumptions can't be
   tested (Composer, Connect Gateway wiring). Invest where local verification is real.

**Key insight:** the Kubernetes layer needs no mocking. Config Sync and Gatekeeper are OSS, the
`tenant-namespace` module speaks the plain `kubernetes` provider, and kind runs locally — so
the entire runtime-plane contract (namespaces, netpol, quota, RBAC, KSAs, constraints,
reconciliation, rendered workloads) can run **for real** on a laptop. Swapping to real GCP is a
provider-config change, not a rewrite.

## Build order (all verifiable without GCP)

1. ~~**Correctness batch**~~ — DONE (2026-07-06): gitops ownership boundary moved out of the
   synced tree + CI guard (`scripts/check-gitops-ownership.rb`); registry guards
   (`scripts/check-registry.rb` + plan-time preconditions); real OPA destroy-threshold override
   (policies v0.10.0 + opa-gate `allow_destroy`); drift detection extended to shared roots;
   docs-vs-code lies fixed (semantic-release claim, phantom log bucket, gates-as-fact, helix's
   inert `dedicated` flags).
2. **Workload delivery path** — the registry's `units.*.version` is currently consumed by
   nothing. Deliver: a delivery ADR (renderer = the ADR-0004 generator graduation; gitops
   ownership amendment for app payload; workload-repo WIF trust — the bootstrap WIF pool is
   hard-scoped to this repo, so workload repos need a second provider + push-only SA); an
   Artifact Registry module; a renderer script in CI stamping per-(tenant, unit, env) manifests
   as reviewable committed diffs (golden-file tests). No Helm, no operator, no per-tenant
   RepoSync yet.
3. **kind-based runtime plane** (the centerpiece): provider-pluggability for
   `terraform/tenant-runtime` (kind vs Connect Gateway); Config Sync OSS + Gatekeeper on kind
   syncing this repo; the scripted end-to-end demo — tenant YAML in → namespace + policies
   appear → renderer stamps workload → Config Sync deploys pod → Gatekeeper rejects a
   default-SA pod → clean offboard. A Temporal OSS dev server joins the demo (ADR-0016).
4. **ADR backlog** (decisions are cloud-free): stateful backends — Cloud SQL/Memorystore need a
   VPC but ADR-0008 gives tenant projects none; lean minimal per-tenant VPC, supersede
   ADR-0008. Ingress/DNS story. DAG authorship (ADR-0015 amendment). ~~Orchestration strategy~~
   — drafted as [ADR-0016](adr/0016-orchestration-strategy-temporal.md) (Temporal for agentic
   work, Temporal Cloud over self-host, namespace-per-tenant mapping, Composer parked).
5. **OPA/Gatekeeper hardening** with synthetic fixtures: deny tenant-project IAM grants to the
   Composer worker SA (keep its IAM starvation by gate, not convention); exact-KSA constraint
   upgrade (testable on kind).
6. **Lifecycle**: offboard `workflow_dispatch` pipeline (payload removal → destroy in the
   tenant's workspace → `workspace delete`; destroy BEFORE deleting the YAML or the workspace
   strands); orphan-workspace CI check; data-retention step; break-glass runbook; Config Sync
   token → keyless (ADR-0012 D12-4).
7. **Workload/SDK integration** (in the workload repos, tracked here for sequencing):
   tenant-supplied knowledge from the tenant's GCS bucket; per-tenant config via
   `feature_flags` → ConfigMap; eval-gate CI check on prod version-bump PRs.
8. **Observability + budgets, code-complete/verify-later**: notification channels wired into
   the observability module (alerts currently fire to nobody); `budget_usd` (dead registry
   field) → `google_billing_budget`; Secret Manager module. All tagged in the verification
   register.

## Activation checklist (when a real GCP org exists)

Org + billing + WIF setup; the bootstrap local-state → bucket → `-migrate-state` dance; set
repo vars (`WIF_PROVIDER` etc. — CI is dormant until then); verify every register entry
(Connect Gateway host, Composer private env, org policies, Gatekeeper on real GKE,
channels/budgets firing, a real drift run); configure GitHub environment protection rules;
mind runtime-plane cost (~$300–400/mo Composer — up/verify/down loop, dev only).

## Event-gated (triggers can't fire in mock mode)

- **Airflow isolation set** (2nd real-data tenant on shared Composer — deferred further by
  ADR-0016's role split): DAG-authorship ADR, Composer-SA IAM-starvation OPA rule, exact-KSA
  constraint, dedicated-compute path (or keep flags opted out).
- **Temporal namespace module + registry task-queue fields** (first consuming workload,
  ADR-0016 D16-4).
- **LLM gateway** (2nd LLM workload/tenant; interim cap = billing budgets).
- **PR change detection** (~10 tenants; full-fleet matrix ≈ 250 jobs at 80 tenants, GitHub cap
  256).
- **platform-modules repo governance**: CODEOWNERS, PRs not direct-to-main, branch protection,
  SHA pins or real release automation (tags are mutable).

## Won't-now (tracked in ADRs)

VPC-SC; per-env appliers; ingestion/BigQuery/compute layer modules; data-unit/app-unit
archetypes; per-tenant RepoSync; self-managed Airflow/Temporal.

## Honest limits

Unverifiable before real GCP: WIF end-to-end, org-policy enforcement, Connect Gateway,
anything Composer, CMEK/HSM, billing budgets, real drift. None of it blocks the build order
above — but every item stays an assumption until the register says otherwise.
