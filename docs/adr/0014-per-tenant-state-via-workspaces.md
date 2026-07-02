# ADR-0014: Per-tenant state via Terraform workspaces (generator-free)

- **Status:** Accepted
- **Date:** 2026-07-02
- **Supersedes:** ADR-0005 (one shared state per environment).

---

## Context

ADR-0005 concluded that per-tenant isolated state "needs either a generator or per-tenant files,
both rejected," and fell back to **one shared state per environment**. That reasoning had a hole:
it never considered **Terraform workspaces**. Workspace-per-tenant gives per-tenant state with no
generator and no per-tenant files — so the ADR-0005 trade-off was a false choice.

Shared-per-env state reintroduces exactly the blast radius D11 feared: one lock, plans that grow
with the fleet, PRs serialized, and a mid-apply failure on one tenant wedging the whole
environment. At ~80 tenants that is untenable.

**Correction to a prior brainstorm:** workspaces do **not** work "on top of the `for_each` model
unchanged." All workspaces run the *same code*, so a `for_each`-over-all-tenants would deploy every
tenant into every workspace's state. Per-tenant state requires **dropping the fleet-wide
`for_each`** and deploying only the workspace's tenant. That is the (small) architecture change
below.

## Decision

**The tenant root deploys one tenant per Terraform workspace.**

- The workspace names the tenant: `slug = coalesce(var.tenant_slug, terraform.workspace)`
  (`tenant_slug` is a test-only override — `terraform test` can't switch workspaces). The root
  reads the whole registry but **selects one** tenant (`lookup(tenants_all, slug)`), guarded by a
  precondition that fails loudly if the workspace isn't a tenant present in this environment.
- **State layout:** backend `prefix = tenants/<env>`, workspace = `<slug>` → one state object per
  `(tenant, environment)`, each with its own lock.
- **CI** becomes a per-tenant matrix built from the registry (`scripts/list-tenant-envs.rb` →
  `{env: [slugs]}`); each job runs `terraform workspace select -or-create <slug>`. Env ordering
  (dev → acc → prod) is preserved via `needs:`; tenants within an env apply in parallel.
- **The generator stays rejected** (D1/D3). Workspaces are not code generation — same config,
  different state. Adding a tenant is still **1 YAML + 1 PR**; CI creates the workspace.

## Scope

Applies to the **tenant (data-plane) root** — the heavy, isolation-critical one. The `runtime` root
is inherently per-environment (shared compute), and `tenant-runtime` is lightweight per-env
namespace orchestration; both stay per-env for now.

## What this does and does NOT fix

- **Fixes:** per-tenant state, lock, plan time, PR parallelism, and blast radius.
- **Does NOT fix:** version divergence. All workspaces still run the same literal module `source`,
  so **fleet-wide versioning stays forced** (ADR-0011) — workspaces isolate *state*, not *versions*.

## Consequences

- The wrong-workspace footgun exists but is mitigated: **CI selects deterministically, never a
  human**.
- ~240 tiny workspaces at 80×3 — cheap; each state is one tenant.
- **Migration** from the current per-env state is state surgery — trivial now (2 tenants), a
  project later. **Do it before ~40 tenants**, or at the first plan-time / PR-serialization pain.
- Enables (future) per-tenant/per-env applier impersonation keyed on the workspace — shrinking the
  fleet-wide god-credential (see ADR-0015).
