# ADR-0026: Cloud-grade tenant lifecycle + eval-gated promotion — closing M4

- **Status:** Accepted
- **Date:** 2026-07-18
- **Builds on:** ADR-0012 (the prune-before-destroy ordering this mechanizes), ADR-0014
  (per-tenant workspaces — the reason "targeted destroy" needs no `-target`), ADR-0017 (the
  renderer whose empty render IS the payload prune, and whose `version` pin is what the eval
  gate protects), ADR-0007 (rollback posture the gate must not tax), ADR-0024 (the Grafana
  org-pruning follow-on closed here).
- **Origin:** the last cloud-free milestone (PLAN.md M4). Offboarding existed only as the live
  demo (`scripts/demo/offboard.sh`) — the ordering was *proven* but enforced by nothing; and
  since ADR-0017 made prod `version` the deployed image tag, nothing distinguished a tested
  promotion from a typo.

---

## Context

Two asymmetries were left after ADR-0023/0024/0025 hardened the runtime plane. First,
**lifecycle**: onboarding is a reviewed PR with CI guards at every seam, but offboarding was a
script a human runs in the right order. The ordering it demonstrates (payload pruned by Config
Sync while the namespace still exists, Terraform destroy only after) is load-bearing — getting
it backwards is exactly ADR-0012's dual-ownership bug — and the cloud version has a second
failure mode the demo can't show: **deleting a tenant's YAML orphans its workspaces**, because
every CI job fans out *from* the registry. Registry-less state is never planned again; its
resources live and bill forever, invisibly. Second, **promotion**: a prod `version` bump merges
on the same review bar as a comment fix.

## Decision

**D26-1. Offboarding is three ordered steps, and the pipeline refuses to run out of order.**

1. **The flag PR** — `offboarding: true` in the tenant YAML plus the (now empty) re-render.
   One reviewed line does two things mechanically: the renderer emits nothing for the tenant
   (Config Sync prunes every workload while namespace and project still stand), and
   `list-tenant-envs.rb` drops the tenant from every plan/apply/drift matrix — frozen, so no
   concurrent deploy can resurrect what the pipeline is about to destroy. This ordering is
   *enforced*, not procedural: the pipeline's credential-less preflight refuses unless the flag
   is merged AND `gitops/payload/*/<slug>/` is empty.
2. **The offboard pipeline** (`offboard.yml`, `workflow_dispatch` only) — retype-the-slug
   confirmation, retention acknowledgment (D26-2), then per declared environment dev→acc→prod:
   a full `plan -destroy` **in the tenant's own workspace** (ADR-0014 makes the workspace the
   targeting mechanism — no `-target`, no resource lists), the OPA gate with `allow_destroy`
   (waiving only the destroy-count threshold; every other deny still applies), apply behind the
   same GitHub environment approval gates as deploys, then `terraform workspace delete` — which
   **fail-closes on non-empty state**: a partial destroy stays visible as a workspace rather
   than vanishing into exactly the orphan this ADR exists to prevent. Re-runs are no-ops per
   already-deleted environment, so recovery from partial failure is "run it again."
3. **The removal PR** — opened *by* the pipeline, last, never first: delete the YAML (+ no-op
   re-render). On merge, deploy.yml's tenant-runtime apply drops the namespace — empty since
   step 1, so prune-before-destroy holds across the whole sequence by construction, separated
   by two human gates rather than a timing assumption.

An independent backstop, because the pipeline being the *only* protection would itself be an
assumption: a scheduled **orphan-workspace check** (drift.yml) diffs `terraform workspace list`
against the registry per environment and opens an issue naming any workspace no YAML backs,
with its state resource count. Mid-offboard tenants (flagged, workspaces intentionally alive)
are expected-state via the matrix script's `_expected` output, not false positives.

**D26-2. Data retention = evidence captured fail-closed, before anything dies.** The pipeline's
read-only inventory job (planner SA) snapshots each environment's `terraform output` (project
id, buckets) plus a full Cloud Asset Inventory sweep of the tenant project into a 90-day run
artifact — if the evidence can't be captured, the destroy jobs never start. Actual
archival/export is deliberately NOT pipeline-automated: retention obligations are per-tenant
contractual facts the platform can't know; the runbook owns the checklist and the operator
acknowledges it as a required dispatch input. Tenant-project telemetry needs no export step —
it dies with the project, which is the correct retention default for isolation-by-project
(ADR-0024's argument, reused).

**D26-3. Break-glass is the same procedure with hands.** The runbook's manual path
(`docs/runbooks/tenant-offboard.md`) is the pipeline's exact steps — same preflight script,
same ordering, same OPA invocation with the same external-data override — for when Actions is
down or WIF is broken. There is deliberately no *second* procedure: an emergency teardown that
skips the ordering is how the dual-ownership bug comes back wearing a pager.

**D26-4. Prod promotion is eval-gated** (`check-eval-gate.rb`, guards job). A PR changing any
unit's **effective** prod version (the same defaults/env shallow merge the renderer does — a
bump hidden in `defaults.units` gates identically) must carry
`evals/<tenant>/<unit>/<version>.yaml` with `verdict: pass`. Scope decisions, each deliberate:
- **Prod-only, opted-in agent-units only** — the archetype with a delivery path; dev runs
  ahead by design and stays friction-free.
- **Changed-versions-only, reports permanent** — a rollback re-lands a version whose report
  exists from its original promotion, so rollback is never taxed (ADR-0007's posture made
  structural).
- **The platform demands evidence; it does not run evals.** Reports come from the application
  repo's eval suite, committed with the bump — the same producer/consumer split as ADR-0020's
  delivery contract.
- **Binary verdict, no backfill.** Anything but `pass` refuses; versions already in prod need
  no retroactive report (fabricated evidence would defeat the point).

**D26-5. Grafana org pruning joins the offboard path** — `provision-orgs.sh --prune` deletes
orgs with no tenant namespace (the ADR-0024 follow-on). Warn-only remains the default: a
missing namespace can also be a broken cluster, so a human passes the flag, from the runbook,
after the namespace is verifiably gone.

## Consequences

- Verified now, locally: renderer's empty-render prune (golden test), matrix freeze, both
  preflight refusal directions, eval gate 9-case battery + a live refusal against a simulated
  `abf` bump, `--prune` live on the kind plane (orphan warned, then deleted; `abf`'s org and
  pinned datasource untouched). All workflows actionlint-clean.
- Cloud seams → register row 17: applier destroy permissions (project deletion, billing
  unlink), `workspace delete` against the GCS backend, planner's Cloud Asset Inventory access,
  environment approval gates on destroy jobs, and the GITHUB_TOKEN seam (pipeline-opened PRs
  don't trigger their own CI — close/reopen to run checks).
- The registry schema grows one field (`offboarding`, strict boolean); `list-tenant-envs.rb`
  grows `_expected`. The local demo (`scripts/demo/offboard.sh`) stays the acceptance test for
  the ordering mechanics; this ADR is its cloud-grade formalization, not its replacement.
- M4 closes. Every remaining PLAN.md item is event- or activation-gated.
