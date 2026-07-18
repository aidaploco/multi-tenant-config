# CI/CD — the plan/apply/policy/drift pipeline

GitHub Actions owns plan and apply directly (ADR-0001 D10 — no Atlantis, no Terraform Cloud).
Everything is **keyless** (D5) and uses the **split planner/applier identities** (D12). The
operations live in **reusable workflows + composite actions** so no component copy-pastes them.

## The pieces

| File | Type | What it does |
| ---- | ---- | ------------ |
| `actions/setup/` | composite action | Keyless GCP auth (WIF) + pinned Terraform. |
| `actions/opa-gate/` | composite action | Pulls OPA policies **pinned** from `platform-modules` and gates the plan (D8). |
| `reusable-plan.yml` | reusable workflow | Read-only plan for one env + gate + PR comment (planner SA). |
| `reusable-apply.yml` | reusable workflow | Re-gated apply for one env (applier SA), behind the env approval gate. |
| `reusable-destroy.yml` | reusable workflow | One tenant workspace's full destroy + workspace delete (applier SA, approval-gated, OPA `allow_destroy`) — ADR-0026. |
| `pr.yml` | caller | On PR: plan **per tenant** (a workspace each) + per-env shared roots, comment diffs. |
| `deploy.yml` | caller | On merge: apply **per tenant**, ordered **dev → acc → prod**, with approvals. |
| `drift.yml` | caller | Scheduled read-only drift check; opens an issue on drift **and** flags orphan workspaces (state no registry entry backs — ADR-0026). |
| `offboard.yml` | caller (`workflow_dispatch` only) | Deliberate tenant teardown: preflight refusals → retention inventory → per-env destroy → registry-removal PR. Runbook: `docs/runbooks/tenant-offboard.md`. |

## The flow (D9 + ADR-0014)

The **tenant root deploys one tenant per Terraform workspace** (ADR-0014). `scripts/list-tenant-envs.rb`
turns the registry into a `{env: [slugs]}` matrix; each job runs `terraform workspace select <slug>`.
Tenants within an env apply in parallel (isolated state); env ordering is enforced by `needs:`.

```
PR opened ─▶ pr.yml: plan each tenant (per workspace) + runtime + OPA gate ─▶ diffs commented
merge to main ─▶ deploy.yml ─▶ apply all dev tenants (auto)
                                   └▶ all acc tenants (reviewer) ─▶ all prod tenants (reviewer)
```

A plan that fails the OPA gate never reaches apply — the gate runs again inside `reusable-apply`.

## One-time setup (these workflows are inert until you do this)

> **Dormant until configured.** Every job is gated on `WIF_PROVIDER` being set. Until you complete
> the setup below, the workflows **skip** (shown as neutral/skipped, not failed) — there are no
> credentials to authenticate with, so there is nothing to run. Red CI on a fresh repo means the
> variables below are missing, not that something is broken.


After `bootstrap/` has been applied, a **platform-team member** configures the repo:

**1. Repository Variables** (Settings → Secrets and variables → Actions → Variables) — from the
bootstrap outputs. These are identifiers, not secrets (D5 means there are no credentials):

| Variable | Source |
| -------- | ------ |
| `WIF_PROVIDER` | bootstrap output `wif_provider_name` |
| `PLANNER_SA` | bootstrap output `planner_service_account` |
| `APPLIER_SA` | bootstrap output `applier_service_account` |
| `TF_STATE_BUCKET` | bootstrap output `state_bucket_name` |
| `BILLING_ACCOUNT`, `PARENT_FOLDER_ID`, `KEYS_PROJECT_ID` | your org values (the `tenants` folder id, etc.) |
| `RUNTIME_FOLDER_ID` | the `runtime` folder id (bootstrap output `folder_ids.runtime`) — for the runtime root |
| `POLICY_REF` | optional override; if unset, the gate auto-uses the **latest** version in `VERSIONS.md` (never stale) |

**2. Environments** (Settings → Environments) — create `dev`, `acc`, `prod`. Add **Required
reviewers** to `acc` and `prod` (this *is* the manual-approval gate; `dev` stays automatic).

**3. Branch protection** on `main` — require PRs + the `plan` checks + "Require review from Code
Owners" (works with `.github/CODEOWNERS`, ADR-0003).

**4. `platform-modules` access.** CI fetches the pinned modules **and** the OPA policies from
`platform-modules` over git. Pick one:
- **Make `platform-modules` public** (recommended — it's reusable modules + policies, no secrets):
  nothing else to do.
- **Keep it private:** add a read-only **`MODULES_READ_TOKEN`** secret (a PAT / fine-grained token
  with read access to `platform-modules`). The workflows use it for both `terraform init` and the
  policy gate. The default `GITHUB_TOKEN` does **not** work — it can't read a *different* repo.

## Not yet verifiable here

Unlike the Terraform (`terraform test`), these workflows can only be fully exercised on GitHub
with a real org behind them. The YAML is syntax-checked; the live run is your first real test.
