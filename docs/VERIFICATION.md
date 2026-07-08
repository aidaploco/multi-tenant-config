# Verification register

This platform is developed **without a live GCP organization** (deliberate: cost). Everything
below is *designed and code-reviewed but unverified against real cloud behavior*. This register
is the honest boundary between "proven" and "assumed" — and it doubles as the **day-one
activation checklist** when a real GCP org exists.

Rules:
- Anything listed here must be presented as an **assumption**, never a fact.
- When adding code whose behavior only a live apply can confirm, add a row.
- When a row is verified for real, record the date and move it to the bottom table.

## Unverified seams

| # | Seam | Where | How to verify |
| - | ---- | ----- | ------------- |
| 1 | Bootstrap first-run dance (local state → bucket → `init -migrate-state`) | `bootstrap/` | Run it, once, on a fresh org |
| 2 | WIF end-to-end: pool `attribute_condition`, planner (any ref) vs applier (`refs/heads/main` only) actually enforced | `bootstrap/wif.tf`, `bootstrap/identities.tf` | From a PR branch, attempt to impersonate the applier — must fail; from main — must succeed |
| 3 | Org policies actually blocking violations (SA keys, external IPs, locations, member domains) | `bootstrap/org-policies.tf` | Try to create each violating resource; expect refusal |
| 4 | Connect Gateway host format for the kubernetes provider ("most apply-sensitive line") | `terraform/tenant-runtime/providers.tf` | Compare against a live Fleet membership; in-cluster RBAC for the applier SA is an operational step. kind mode (ADR-0018) bypasses this transport entirely by design, so it stays fully untested until a real cluster exists |
| 5 | Composer private-environment config accepted as written | `modules/cloud-composer` | First runtime apply (⚠ ~$300–400/mo — use the up/verify/down loop, dev only) |
| 6 | Config Sync **installs via Fleet** (the `gke_hub` feature + membership registration) and Policy Controller **enables via Fleet** | `modules/config-sync` | First runtime apply. (The reconciliation/prune/admission *mechanics* this used to cover are now verified on kind — see below; this row is narrowed to the Fleet-specific install path only) |
| 7 | Applier folder-role set is sufficient (and not over-broad) for a full tenant + runtime apply | `bootstrap/locals.tf` | First full apply; then tighten |
| 8 | CMEK/HSM: key creation, GCS service-agent grant ordering, HSM protection level in europe-west4 | `modules/kms-tenant`, `modules/gcs` | First tenant apply |
| 9 | Drift detection semantics (`-detailed-exitcode` per workspace and per shared root) | `.github/workflows/drift.yml` | Introduce deliberate out-of-band drift in dev; expect an issue |
| 10 | GitHub environment protection gates on `acc`/`prod` | repo settings (not code) | Configure environments; require reviewers; test a merge |
| 11 | CODEOWNERS teams + branch protection ("inert on its own") | `.github/CODEOWNERS` | Needs a GitHub org with the two teams + branch protection enabled |
| 12 | Notification channels / billing budgets fire to a human (once built — tracked in the plan) | observability work | Trigger a test alert; overspend a dev budget |
| 13 | Config Sync cluster name on **GKE/Fleet** equals `runtime-<env>` (ConfigManagement sets this from the membership name), so `cluster-name-selector`s scope the app payload per environment (ADR-0017 D17-3) | `gitops/payload/`, `modules/config-sync` | Fleet install: confirm/set the ConfigManagement cluster name per env cluster. The OSS half (`CLUSTER_NAME` env var on `reconciler-manager`) is verified below |

## Verified

| Date | Seam | Evidence |
| ---- | ---- | -------- |
| 2026-07-07 | `tenant-runtime` applies the full namespace isolation contract (namespace, both NetworkPolicies, quota, limit range, RBAC, unit KSA) with `cluster_mode = kind` and zero GCP credentials | 8 resources created on a local kind cluster (ADR-0018) |
| 2026-07-07 | Config Sync OSS syncs `gitops/` from a **private** repo via a token Secret, and `configsync.gke.io/cluster-name-selector` correctly scopes per-environment payload (only dev's manifest applied on the dev-named cluster, prod's was not) | `RootSync` synced cleanly (`errorSummary: {}`); `kubectl get deploy -n abf` showed only the dev unit |
| 2026-07-07 | Config Sync **prunes** a removed payload object on the next reconcile (the M3/M4 offboard-ordering dependency) | Opted a unit out in the registry, re-rendered, pushed — the live Deployment+Service were deleted; reverted and they returned |
| 2026-07-07 | Gatekeeper (OSS, same engine as Policy Controller) enforces `deny-default-sa` AND the new exact-KSA constraint (`K8sTenantUnitKsa`, ADR-0018) at admission | Pod as `default` SA — denied by both. Pod as a real, named, non-unit SA — denied by exact-KSA specifically (proving it does more than deny-default-sa alone). Pod as the unit's actual KSA — admitted |
| 2026-07-07 | Temporal dev server (`temporalio/temporal:1.7.2`, ADR-0019) runs in-cluster with PVC persistence and reaches Ready | Deployment `1/1`, PVC `Bound`; logs show frontend on `:7233`, UI on `:8233` |
| 2026-07-07 | Per-(tenant, environment) Temporal namespace provisioning (`scripts/temporal/create-namespaces.sh`, ADR-0016 D16-3) is data-driven and idempotent | All 5 current tenant×env pairs registered in one run; a second run reported all 5 "already exists, skipping"; `temporal operator namespace list` showed all 5 with the expected description |
| 2026-07-07 | The rendered payload's `TEMPORAL_ADDRESS`/`NAMESPACE`/`TASK_QUEUE` env vars are not just set but actually reachable (ADR-0019) | A live TCP connect from inside the `search-a` pod to `temporal-frontend.platform-system.svc.cluster.local:7233` (the exact value of its own `TEMPORAL_ADDRESS`) succeeded, cross-namespace |
| 2026-07-08 | The first real agent workload (`customer-service-agent`, ADR-0020) runs end-to-end: two units from one image (`command` override + headless `expose_port: false`), app secrets via `envFrom` on a human-created Secret, Postgres/Redis reachable via `host.docker.internal`, and — the definitive check — an actual registered Temporal poller | Both pods `Running`, 0 restarts post-Secret (prior 5 restarts were a correct `openai_api_key` fail-fast, not a bug); API logs show a real Postgres connection + RAG ingestion; `temporal task-queue describe --task-queue cs-agent --namespace abf-dev` showed 2 active pollers (workflow + activity) identified by the worker pod's own name; both pods run as their own KSA, not `default` |
| 2026-07-08 | **The project's stated acceptance test**: a durable conversation survives its worker pod being killed outright, with zero application-level recovery code | `scripts/demo/pod-kill-and-resume.sh`: real turn via the API -> kill the worker pod -> replacement pod re-registers as a poller -> same workflow run ID -> agent correctly recalls context from before the kill through a genuine LLM call. First fix needed: a shared long-lived port-forward under Docker Desktop drops rapid individual connections (`connection reset by peer`) often enough to starve a tight retry loop — resolved with a fresh port-forward per Temporal CLI call |
| 2026-07-08 | Clean tenant offboard holds the ordering the design depends on: payload pruned by Config Sync BEFORE Terraform destroys the namespace | `scripts/demo/offboard.sh`, a throwaway tenant, real commits/applies both directions: namespace created -> payload live -> registry entry removed -> payload pruned (namespace still exists — the ordering check) -> `terraform apply` destroys the now-unreferenced namespace. All 5 checks passed on the first live run; registry left exactly as it started |
| 2026-07-08 | D16-5 payload codec (`customer-service-agent`, image `0.2.1`): conversation content is encrypted in Temporal's history, not plaintext | App-side integration test (`a1bd1d8`) fetches raw history through a codec-less client and asserts payloads are ciphertext nowhere-plaintext; platform-side, the delivered `TEMPORAL_PAYLOAD_CODEC_KEY` decoded to exactly 32 raw bytes (verified directly against the stored Secret) |

Locally verifiable WITHOUT GCP (do these instead of waiting): OPA policies (`conftest verify`),
module wiring (`terraform test` with mocks), registry + gitops-ownership guards (`ruby
scripts/check-*.rb`), and, as of M2, the full namespace isolation contract, Config Sync
reconciliation/pruning, and Gatekeeper constraints — all now exercised live via
`scripts/kind/up.sh` rather than merely reviewed.
