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
| 4 | Connect Gateway host format for the kubernetes provider ("most apply-sensitive line") | `terraform/tenant-runtime/providers.tf` | Compare against a live Fleet membership; in-cluster RBAC for the applier SA is an operational step |
| 5 | Composer private-environment config accepted as written | `modules/cloud-composer` | First runtime apply (⚠ ~$300–400/mo — use the up/verify/down loop, dev only) |
| 6 | Config Sync installs via Fleet, syncs `gitops/`, and PRUNES removed objects | `modules/config-sync`, `gitops/` | First runtime apply + delete a synced object from git |
| 7 | Policy Controller enforces `deny-default-sa` (reviewed, never run) | `gitops/cluster/deny-default-sa.yaml` | Deploy a default-SA pod in a tenant namespace; expect admission denial. Partially verifiable earlier on kind + Gatekeeper OSS |
| 8 | Applier folder-role set is sufficient (and not over-broad) for a full tenant + runtime apply | `bootstrap/locals.tf` | First full apply; then tighten |
| 9 | CMEK/HSM: key creation, GCS service-agent grant ordering, HSM protection level in europe-west4 | `modules/kms-tenant`, `modules/gcs` | First tenant apply |
| 10 | Drift detection semantics (`-detailed-exitcode` per workspace and per shared root) | `.github/workflows/drift.yml` | Introduce deliberate out-of-band drift in dev; expect an issue |
| 11 | GitHub environment protection gates on `acc`/`prod` | repo settings (not code) | Configure environments; require reviewers; test a merge |
| 12 | CODEOWNERS teams + branch protection ("inert on its own") | `.github/CODEOWNERS` | Needs a GitHub org with the two teams + branch protection enabled |
| 13 | Notification channels / billing budgets fire to a human (once built — tracked in the plan) | observability work | Trigger a test alert; overspend a dev budget |

## Verified

| Date | Seam | Evidence |
| ---- | ---- | -------- |
| — | *(nothing yet — the honest starting point)* | |

Locally verifiable WITHOUT GCP (do these instead of waiting): OPA policies (`conftest verify`),
module wiring (`terraform test` with mocks), registry + gitops-ownership guards (`ruby
scripts/check-*.rb`), and — once the kind-based runtime plane lands — the full namespace
isolation contract, Config Sync reconciliation, and Gatekeeper constraints on a local cluster.
