# ADR-0019: Temporal dev server, demo namespace provisioning, and payload env wiring

- **Status:** Accepted — infra live-verified 2026-07-07; worker/codec wiring explicitly deferred
- **Date:** 2026-07-07
- **Builds on:** ADR-0016 (Temporal orchestration strategy — D16-2's local/dev exception, D16-3's
  tenancy mapping, D16-4's build trigger), ADR-0017 (payload renderer), ADR-0018 (kind plane).

---

## Context

ADR-0016 decided Temporal's shape (Cloud in real environments, an OSS dev server locally) and
its tenancy mapping (one namespace per tenant×environment, one task queue per tenant×unit) but
built none of it — correctly, since D16-4 gates the real `temporal-namespace` Terraform module
on "the first workload consumes it." That workload (`example-agent`) does not have
Temporal integration yet — checked directly: no workflow/worker code, only Dockerfiles for a
plain FastAPI/GraphQL app. Building the Terraform module now would be speculative infrastructure
for a consumer that doesn't exist.

What *is* buildable now, independent of the agent repo: the dev server itself, the per-tenant
namespace mechanics standing in for the deferred module, and the delivery-path wiring that gets
a worker connected the moment one exists. This ADR scopes M3 to exactly that — **platform
infrastructure only**. The worker, the D16-5 codec implementation, and the pod-kill-and-resume
demo itself are explicitly deferred; they need real workflow code this repo doesn't own.

## Decisions

**D19-1. The dev server is the `temporal` CLI's own image, not a hand-assembled server
config.** `temporalio/temporal:1.7.2` running `server start-dev --db-filename /data/temporal.db`
on a PVC in `platform-system` (Config-Sync-owned, shared platform workload per ADR-0012 D12-3 —
same namespace class as the baseline itself, not per-tenant). This is the identical binary
`brew install temporal` gives you; no bespoke Dockerfile, no manual schema setup the way
`temporalio/auto-setup` would need. Persistence matters specifically because the demo's whole
point is killing a *worker* pod and confirming the workflow resumes — that assertion is checked
against the server's history, so the server's own state must survive incidentally (a Recreate
deployment strategy, not a second replica, since two processes cannot share one sqlite file).

**D19-2. Namespace provisioning is a script, deliberately not the Terraform module.**
`scripts/temporal/create-namespaces.sh` reads the same registry (`scripts/list-tenant-envs.rb`'s
tenant×environment pairs) and calls `temporal operator namespace create` for
`<tenant>-<environment>` — the same naming convention already used for GCP project IDs
(`abf-dev`). This is **explicitly not** the graduation of D16-4's trigger: the trigger is a real
Temporal-consuming workload, not "an ADR wants namespaces to exist for a demo." When
`example-agent` actually connects, the `temporal-namespace` Terraform module (gated on
the `temporalio/temporalcloud` provider) replaces this script for real environments; the script
may still be worth keeping for the local kind demo, since Temporal Cloud is never free there.

**D19-3. Payload wiring: three env vars, no codec.** `scripts/render-payload.rb` now sets
`TEMPORAL_ADDRESS` (the in-cluster dev-server Service DNS — a Temporal Cloud endpoint at
activation, same variable), `TEMPORAL_NAMESPACE` (`<tenant>-<environment>`, matching D19-2's
naming), and `TEMPORAL_TASK_QUEUE` (the registry's new `units.*.task_queue`, defaulting to the
unit name) into every agent-unit's container. **The D16-5 codec key is NOT wired.** Delivering
it (even a shared dev-mode static key) means deciding a concrete shape — Secret vs ConfigMap,
mount path, env var name — that only makes sense once the consuming worker's SDK config exists
to dictate it. Wiring it blind risks guessing wrong and re-doing it; ADR-0016 already assigns
codec *implementation* to the workload repo, so its exact delivery contract should follow from
there, not be invented here.

**D19-4. What this explicitly does not build.** No worker, no workflow/activity code, no
pod-kill-and-resume demo script, no offboard demo. All of it needs
`example-agent` to have real Temporal integration first — tracked as a dependency, not
built speculatively in this repo (ADR-0016's non-goals: "workflow/activity definitions... belong
to the workload repos").

## Consequences

- The moment the agent repo adds a Temporal worker and points it at these three env vars, it
  should connect with zero platform-side changes — the wiring is ready and waiting, not
  something to retrofit later.
- `docs/VERIFICATION.md` gains verified rows for the dev server and live namespace creation;
  `docs/PLAN.md`'s M3 entry stays open, explicitly listing the deferred items above as blocked
  on the agent repo, not abandoned.
- The task-queue naming convention (`<unit>` default) means a tenant can override it without any
  platform code change — just a registry field, consistent with how `version` and `image`
  already work.
