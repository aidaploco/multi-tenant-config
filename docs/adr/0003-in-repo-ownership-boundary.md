# ADR-0003: In-repo ownership boundary (CODEOWNERS)

- **Status:** Accepted
- **Date:** 2026-06-29
- **Extends:** ADR-0001 D1 (the two-repo model). Does **not** supersede it — we keep exactly two
  repos and add a path-level ownership boundary *inside* `multi-tenant-config`.
- **Supersedes:** none

---

## Context

ADR-0001 D1 established that **`multi-tenant-config` is the only repo FDEs (forward-deployed
engineers) touch**, while `multi-tenant-platform` stays platform-team-only. The clean intent: tenant
teams edit data (their tenant YAML); they never touch platform internals.

But `multi-tenant-config` has since grown to contain more than the tenant registry:

- `bootstrap/` — the org foundation: day-zero **org policies**, the **WIF** trust, and the
  **applier** service account's IAM (the privilege boundary itself).
- `policies/` — the OPA policy gate.
- `terraform/` — the deployment engine that loops over the registry.
- `.github/` — CI.

These are precisely the controls that are supposed to **contain** FDEs. With them in the
FDE-editable repo, an FDE PR could *propose* weakening an org policy (e.g. re-allowing public
IPs), granting the `applier` identity more power, or loosening the WIF branch conditions that
keep that identity unreachable from pull requests (ADR-0001 D12).

Two existing controls soften this but do not close it:

1. `bootstrap/` is **applied by hand by an Org-Admin human**, never by CI — a bad merge does
   not auto-deploy.
2. Branch protection on `main` means all changes are reviewed PRs.

The gap: **review was the *only* gate on the sensitive paths**, with no guarantee that a
*platform* engineer (rather than an FDE peer) performed it.

## Decision

**Keep two repos. Enforce a path-level ownership boundary with `CODEOWNERS` + branch
protection.**

| Path | Approval required to merge |
| ---- | -------------------------- |
| `tenants/*.yaml` | FDE **or** platform team (+ the OPA gate as automated backstop) |
| `bootstrap/`, `policies/`, `terraform/`, `.github/`, `docs/adr/`, `VERSIONS.md` | **Platform team only** |

`CODEOWNERS` is inert without the supporting GitHub configuration, which is part of this
decision:

1. Branch protection on `main` with **"Require review from Code Owners"** enabled.
2. A platform-team GitHub team (write) and an FDE-team GitHub team.
3. The existing D12 control stands: CI may `apply` only from `main` via the `applier` SA; the
   `bootstrap/` root is never applied by CI at all.

## Why not a third repo

Pulling `bootstrap/` into its own platform-team-only "landing zone" repo is a legitimate and
common industry pattern, and gives a *harder* boundary (separate write permissions, not just
path rules). We decline it **for now** because ADR-0001 D1 deliberately chose two repos for
operational simplicity at a 3-engineer scale, and a third repo is another state file, CI setup,
and thing to operate. `CODEOWNERS` delivers most of the safety at a fraction of the cost.

**This door stays open:** if the team grows or an auditor requires a hard permission split,
moving `bootstrap/` to its own repo is a clean follow-up that would supersede this ADR.

## Consequences

- **Defense in depth on the foundation:** CODEOWNERS merge-gate **+** manual Org-Admin apply
  **+** WIF branch condition. Three independent layers, not one.
- **FDE flow is unchanged:** they still open tenant PRs freely; only the blast-radius paths now
  require platform sign-off.
- **Residual (accepted):** FDEs retain *read* access to `bootstrap/`, exposing org identifiers
  (org ID, billing account, customer ID). Low risk — these are identifiers, not credentials,
  and ADR-0001 D5 means there are no downloadable credentials to expose anywhere.
