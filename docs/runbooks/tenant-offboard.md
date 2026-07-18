# Runbook: tenant offboarding (normal path + break-glass)

Companion to ADR-0026. The invariant everything below protects, in one line:

> **Payload pruned → infrastructure destroyed → registry entry deleted. Never another order.**

Prune-before-destroy is ADR-0012's dual-ownership rule (Config Sync must remove its objects
while the namespace still exists); destroy-before-YAML-delete is ADR-0026's orphan rule (a
deleted registry entry makes the tenant's workspaces invisible to all CI forever — state with
live, billing resources that nothing will ever plan again).

## Normal path (three steps, two PRs, one pipeline)

**1. The flag PR.** One line + the re-render, nothing else in the PR:

```bash
# in tenants/<slug>.yaml, top level:
#   offboarding: true
ruby scripts/render-payload.rb        # renders the tenant's payload EMPTY — this is the prune
git add tenants/<slug>.yaml gitops/payload
```

On merge: Config Sync prunes every workload; the tenant leaves all plan/apply/drift matrices
(frozen). The namespace and project deliberately stay up. Verify the prune on the live cluster
before proceeding: `kubectl get deploy -n <slug>` → nothing.

**2. The pipeline.** Actions → `offboard` → Run workflow. Inputs: the slug, the slug again
(confirmation), and the retention acknowledgment — which asserts you have completed the
**data-retention checklist**:

- Does this tenant's contract/regulatory regime require data export before deletion? If yes,
  export from the tenant project's buckets/datasets **now** — the pipeline captures an
  *inventory* (terraform outputs + Cloud Asset Inventory sweep, a 90-day artifact on the run),
  it does not archive content (ADR-0026 D26-2: obligations are per-tenant facts the platform
  can't know).
- Temporal: per-tenant namespaces hold workflow *histories* (encrypted per D16-5). Terminate or
  drain open workflows first; namespace retention follows the Temporal-side config, not this
  pipeline.

The pipeline then runs preflight refusals (flag merged? payload gone?), the inventory, and
per-environment destroys dev→acc→prod — each a full `plan -destroy` in the tenant's own
workspace, OPA-gated (`allow_destroy` waives only the destroy-count threshold), behind the same
acc/prod approval gates as deploys — then deletes each workspace. **A re-run after any partial
failure is safe and is the recovery procedure**: completed environments no-op.

**3. The removal PR** — opened by the pipeline. Review, close/reopen it (pipeline-opened PRs
don't self-trigger CI — the GITHUB_TOKEN seam, register row 17), merge. deploy.yml's
tenant-runtime apply drops the long-empty namespace.

**Aftercare (local metrics plane):** once the namespace is gone,
`scripts/grafana/provision-orgs.sh --prune` deletes the tenant's Grafana org (warn-only without
the flag — deliberate; ADR-0026 D26-5). At activation this is the Terraform Grafana provider's
job instead (register row 15).

## Break-glass: manual offboard when CI can't run

Same procedure, same order, by hand (ADR-0026 D26-3: there is no "emergency shortcut" —
skipping the ordering is how the dual-ownership bug returns). Prerequisites: step 1's flag PR
**must still merge first** (or, if GitHub itself is down, be committed to main by an admin with
the re-render); you need applier-level GCP credentials and `MODULES_READ_TOKEN`-equivalent git
access.

```bash
# 0. Refuse early, like the pipeline would:
ruby scripts/offboard-preflight.rb <slug>          # prints the env list on success

# Per environment the preflight printed, in order dev, acc, prod:
cd terraform/tenants
terraform init -input=false \
  -backend-config="bucket=<TF_STATE_BUCKET>" -backend-config="prefix=tenants/<env>"
terraform workspace select <slug>

# 1. Destroy plan + the same OPA gate the pipeline runs (allow_destroy via external data —
#    policies >= v0.10.0; the exceptions file is exactly what .github/actions/opa-gate writes):
terraform plan -destroy -input=false -out=plan.tfplan \
  -var environment=<env> -var billing_account=<...> \
  -var parent_folder_id=<...> -var keys_project_id=<...>
terraform show -json plan.tfplan > plan.json
echo '{"exceptions": {"allow_destroy_over_threshold": true}}' > /tmp/opa-exceptions.json
conftest test plan.json --policy <platform-modules checkout>/policies --data /tmp/opa-exceptions.json

# 2. Only if the gate passed:
terraform apply -input=false plan.tfplan
terraform workspace select default
terraform workspace delete <slug>      # refuses on non-empty state — do NOT -force; a refusal
                                       # means the destroy is incomplete, go look at the plan

# Last, never first: delete tenants/<slug>.yaml, re-render (no-op), commit to main.
```

If you had to bypass the flag PR (GitHub fully down): the CI-matrix freeze never happened, so
do NOT leave a half-offboarded tenant overnight — either finish all environments + the YAML
removal, or revert the flag commit.

## Failure modes

| Symptom | Meaning | Action |
| ------- | ------- | ------ |
| Preflight: "payload still present" | Flag merged but re-render didn't, or render stale | Merge the correct flag PR; never destroy past this refusal |
| Destroy job fails mid-environment | Partial destroy; state still holds the remainder | Re-run the pipeline — completed envs no-op, the failed env re-plans exactly what's left |
| `workspace delete` refuses | State not empty — destroy incomplete | Investigate the remaining resources (`terraform state list`); re-run. Never `-force` |
| Orphan-workspace issue opens | A workspace exists that no registry entry backs | If mid-offboard: finish the pipeline. Otherwise: someone deleted YAML without the pipeline — run the break-glass path for that slug to destroy-then-clean |
| Removal PR has no CI checks | GITHUB_TOKEN seam | Close/reopen the PR (or push an empty commit) |
