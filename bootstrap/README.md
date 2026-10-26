# bootstrap — Phase 0 (the one-time foundation)

This is the **only** thing in the platform that is applied **by hand, once, by a human with
Organization-Admin rights**. Everything else (every tenant, every environment) is applied by
CI afterwards. Phase 0 builds the ground that CI then stands on:

| What it creates | Why it has to exist first | ADR |
| --------------- | ------------------------- | --- |
| Org-level **folders** (`tenants/`, `runtime/`, `platform/`) | Somewhere to put projects; policy inheritance points. | D2 |
| A **management project** | Holds the Terraform state and the CI identities. | — |
| A **CMEK-encrypted state bucket** | Where every later apply stores its state, encrypted with our own key. | D6 |
| **Day-zero Org Policies** | Make insecure things *impossible to create by accident*, from minute one. | D4, D5, D8 |
| A **Workload Identity Federation pool** for GitHub | Lets CI authenticate with **no downloadable keys**. | D5 |
| **Two** CI service accounts — a read-only `planner` and a write `applier` | The single most important security split: untrusted PR code can only *look*, never *change*. | D12 |

## The chicken-and-egg, explained plainly

This root creates the very state bucket that Terraform would normally store its state in — so
on the **first** run there is nowhere remote to put the state yet. The standard, safe dance:

1. Run it once with **local state** (the `backend "gcs"` block in `versions.tf` stays commented).
2. It creates the management project, the KMS key, and the state bucket.
3. **Then** uncomment the `backend "gcs"` block, point it at the bucket it just made, and run
   `terraform init -migrate-state` to move the local state into the bucket.

After that, this root is essentially frozen — you only touch it to add an org policy or rotate
a CI identity, which a human does deliberately, never CI.

## How to actually run it (you, not me)

I can't run this — it needs a real GCP organization, a billing account, and Org-Admin
credentials none of which exist in this workspace. When you're ready, **you** drive it. In a
Claude Code session you can run the login inline so the output lands here:

```
! gcloud auth application-default login
```

Then, from this directory:

```bash
cp terraform.tfvars.example terraform.tfvars   # fill in your real org_id, billing account, etc.
terraform init
terraform plan -out plan.tfplan                # READ THIS DIFF before applying
terraform apply plan.tfplan
```

> **Status: reviewed scaffolding, not deployed.** Every file here is internally consistent and
> written to the platform's conventions, but it has never touched a real cloud. The role grants
> on the `applier` identity (`identities.tf`) are the security-sensitive part — have a second
> human read those specifically before the first apply.

## What this is NOT

Not a reusable module (so no `tests/` or `example/` — those are for `multi-tenant-platform`). It is a
one-off **root**, environment-specific by nature, so it lives in `multi-tenant-config`, not in the
module library.
