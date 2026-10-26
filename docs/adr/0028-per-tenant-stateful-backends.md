# ADR-0028: Per-tenant stateful backends — managed, PSC-connected, and still no tenant VPC

- **Status:** Accepted (decision-only — **no module until activation**, see D28-5)
- **Date:** 2026-07-18
- **Builds on:** ADR-0008 (whose "tenant projects have no VPC" this *reaffirms*, against the
  backlog's own expectation of superseding it), ADR-0001 D14 (isolation follows the project
  boundary), ADR-0020 (the `secret_ref` delivery contract this rides on, unchanged),
  ADR-0006/0025 (per-tenant CMEK doctrine), ADR-0016/0024 (the self-hosted-stateful Won't-now
  posture and the argument for why monitoring was the exception).
- **Origin:** the last ungated item in PLAN.md. The consumer has existed since ADR-0020: both
  real workloads run on Postgres (example-agent also Redis) — locally via host-run Docker and
  `host.docker.internal` URLs in their `secret_ref` Secrets.

> **Amended same day (2026-07-18, landscape clarification):** `example-agent` exited
> the platform landscape — it was a reference example for the app repo, never a platform
> workload. Consequences for this ADR: **Postgres keeps its consumer** (`agent-chassis`
> uses it); **Redis now has none** (Lana keeps conversation state in Temporal workflow state —
> the design example-agent's Redis store predated). The `redis` layer decision stands as written
> but is now consumer-gated like everything else here: no tenant declares it until a workload
> actually needs Redis, and the Memorystore-Cluster-vs-classic caveat is decided then. The
> PSC/no-tenant-VPC architecture (D28-2) is engine-agnostic and unaffected. ADR-0008 explicitly scoped tenant
  data projects to "no VPC of their own," and Cloud SQL/Memorystore have historically wanted
  one. That tension needed a decision, not a workaround.

---

## Context

The classic way to give tenant projects managed databases is private services access: a VPC in
the consumer project, a peered Google-managed range, instances on private IPs inside it. That
path would genuinely supersede ADR-0008 — every tenant project grows a network, peering to the
runtime VPC, and all the transitive-routing and quota pain of an N-tenant peering mesh.

**Private Service Connect (PSC) removes the premise.** A PSC-enabled Cloud SQL instance needs
no VPC in its own project — Google manages the producer side; the *consumer* endpoint is
created in the VPC that wants to reach it. This platform has exactly one real VPC per
environment (the runtime VPC, ADR-0008 D-N1), which is precisely where the workloads that need
these backends run.

## Decisions

**D28-1. Stateful backends are per-tenant managed services in the tenant's own project.**
Cloud SQL (Postgres) and Memorystore (Redis), one instance of each opted-in engine per tenant
per environment, living where every other tenant datum lives: isolation is the project
boundary + per-tenant CMEK (`kms-tenant`, the ADR-0006 pattern) + IAM, cost lands on the
tenant's `budget_usd`, and offboarding destroys them with the project (their data retention is
exactly the ADR-0026 D26-2 inventory + runbook obligation). Explicitly rejected:
- *Self-hosted Postgres/Redis on the shared cluster* — the ADR-0016 Won't-now applies;
  ADR-0024 argued why self-hosted *monitoring* was acceptable (disposable, `emptyDir`,
  nothing precious), and databases are the opposite of that argument.
- *Backends in the runtime project* — breaks tenant isolation, CMEK, billing attribution, and
  the offboard story in one move.
- *Per-unit instances* — an API and its worker share state by design (they already share a
  `secret_ref`); the grain is the tenant-environment, with **one database/user per role**
  inside the instance (`example-agent`, `lana`, …).

**D28-2. Connectivity is PSC. ADR-0008 stands: tenant projects still get no VPC.** The
runtime VPC holds one PSC consumer endpoint per tenant backend; workloads reach it over the
network they already run on, and tenant east-west isolation at that layer remains the
namespace NetworkPolicy story (egress to private ranges is already denied by default —
ADR-0022's allow-list will need a scoped per-tenant exception for the tenant's own endpoint
IPs, *not* a blanket private-range opening; that is the one genuinely new network surface and
it must be rendered per tenant, never shared). Rejected: per-tenant VPCs + peering (the mesh),
and Shared VPC (re-centralizes network admin into exactly the coupling ADR-0008's design
avoids). **One honest caveat:** classic Memorystore for Redis still wants an authorized VPC
(private services access); Memorystore **Redis Cluster** uses PSC. The decision is Cluster
edition; if a real workload ever forces classic Redis, *that* — and only that — reopens the
minimal-tenant-VPC question, as its own recorded amendment.

**D28-3. Registry shape: two new layers, zero new mechanics.** `postgres: { opt_in }` and
`redis: { opt_in }` join the axis-1 layers; the tenant module's `try(layers.<name>.opt_in,
false)` pattern, conditional API enablement, and schema v2 all extend without machinery
changes. Not per-unit `overrides:` — the instance is tenant-environment-scoped (D28-1), so it
is layer-shaped, like storage. `restricted` tenants may opt in freely: the backend is in
*their* project; only the consumer endpoint placement follows their (dedicated, not-yet-built)
compute plane — the registry-honesty rule about flags that provision nothing applies until
then.

**D28-4. The delivery contract does not change.** Apps keep reading `POSTGRES_URL` /
`REDIS_URL` from their human-created `secret_ref` Secret (ADR-0020). Today those values point
at host-run Docker (`host.docker.internal`) — **now blessed as the kind-mode half of the
contract**, not an embarrassment to hide: it is the same migrate-by-changing-the-value story
as `IMAGE_REGISTRY` and `TEMPORAL_ADDRESS`. At activation the values become the PSC endpoint
DNS. North star for auth is IAM database authentication over Workload Identity (no standing
passwords — the keyless doctrine extended to data), but that is decided *against a real
instance* at activation; password-in-Secret is the documented interim, same bar as the Config
Sync PAT (ADR-0012 D12-4: named, dated, not pretended away). PITR/backups default-on,
per-tenant CMEK on the instances (D25-1's fail-closed posture: the module, when it exists,
refuses to build without a key).

**D28-5. No module until activation — stated as its own decision so it can't erode.** The
consumer exists but the cloud doesn't: a Cloud SQL module that can never be applied is
unverifiable code accruing register rows (the mock-first rule: invest where local verification
is real). Local demos need nothing built — the host-run pattern works and is verified weekly
by the acceptance demo. If a demo ever *needs* platform-provisioned local state (gate: a
workflow that must survive with zero host dependencies), an in-cluster per-tenant Postgres
rendered like Phoenix (ADR-0027) is the shape — noted, not built.

## Consequences

- ADR-0008 is **reaffirmed, not superseded** — the backlog entry assumed the opposite; the
  decision record now explains why the no-VPC posture survives contact with stateful backends.
- Activation checklist: the stateful-backend module (both engines, PSC, CMEK, layer wiring)
  plus register rows for everything only a live org proves: PSC producer setup and
  allowed-consumer configuration on Cloud SQL, Memorystore Redis Cluster's service-connection
  policy and where it lives, endpoint DNS shape, the per-tenant egress exception rendering,
  IAM DB authn vs interim passwords, `sql.restrictPublicIp`/org-policy interactions, and
  instance CMEK acceptance.
- The ADR backlog is now **empty of ungated items**: everything remaining in PLAN.md has a
  named external trigger (MCP-authz → Second Brain's design; ingress/DNS → first external
  user; the event-gated set; activation).
