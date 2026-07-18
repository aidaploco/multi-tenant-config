# ADR-0027: Per-tenant Phoenix trace plane — instances, not projects, as the boundary

- **Status:** Accepted
- **Date:** 2026-07-18
- **Builds on:** ADR-0024 (the argument for self-hosted observability in the shared plane, and
  the Grafana-org precedent this deliberately does NOT follow), ADR-0023 (D23-3 exact-dataflow
  NetworkPolicies — the enforcement mechanism), ADR-0017/0019 (the renderer and the
  `TEMPORAL_*` env-var delivery pattern, both reused verbatim), ADR-0016 D16-5 (the
  encryption decision a trace backend must not quietly undo), ADR-0012 D12-3 (the ownership
  boundary the new rendered tree had to be admitted into explicitly).
- **Origin:** the consumer gate fired. Both real workloads emit OTLP today, and the trace
  *backend* (Arize Phoenix + its Postgres) lived in `customer-service-agent`'s docker-compose
  — one product app maintaining shared observability infrastructure that a second product app
  (`ai-employees-core`) reached through `host.docker.internal`. Two boundary violations;
  flagged by Aida, confirmed by reading both repos.

---

## Context

Instrumentation and backend are different things. The OTel SDK code — span semantics, the
replay-safe Temporal tracer provider, the fail-soft no-endpoint posture — belongs in the apps
and stays there untouched. The collector/backend is cross-cutting infrastructure, exactly like
Prometheus/Grafana (ADR-0024) and the Temporal dev server (ADR-0019). Two hard problems made
this an ADR rather than a copy of ADR-0024's shape:

1. **Trace spans carry plaintext conversation content.** D16-5 exists specifically to keep
   that content ciphertext in Temporal's shared history; a *shared* trace store would
   reintroduce the exact leak on a different port.
2. **Phoenix OSS's multi-tenant authz is weak.** Projects are namespacing for organizing use
   cases, not an isolation boundary — nothing stops an authenticated user of a shared
   instance from reading another project's traces.

The reference pattern (Aida's employer): **one Phoenix instance per tenant**, each with its
own URL; projects *within* an instance organize that tenant's use cases. That dissolves both
problems at once and is adopted here.

## Decision

**D27-1. One Phoenix instance per tenant per environment, in `platform-system`, rendered from
the registry.** `render-payload.rb` emits `gitops/platform/<env>/phoenix-<slug>.yaml`
(ServiceAccount, Deployment, Service, NetworkPolicy — pinned `15.11.1-nonroot`, hub tag
verified) for every tenant with ≥1 rendered agent-unit in that environment. Instance-level
isolation means Phoenix's project model is *free to be what it's good at* — organizing a
tenant's use cases (each unit's `service.name` lands in its own project) — while carrying zero
security weight. Consequences of "rendered, not hand-written": a new tenant gets a trace
backend with no extra PR; an **offboarding tenant's instance is pruned in the same commit as
its payload** (the ADR-0026 flag covers traces automatically, unlike Grafana orgs which needed
D26-5); and the tree is drift-checked like the payload.

**D27-2. The NetworkPolicy is the tenant boundary, per instance.** Ingress to `phoenix-<slug>`
pods on 6006 only from the namespace carrying the Terraform-stamped `tenant: <slug>` label —
the same trusted signal Gatekeeper referential data uses (ADR-0018). `platform-system`'s
default-deny (ADR-0023) does the rest; tenant→`platform-system` egress was already in the
ADR-0022 allow-list. This is the D23-3 doctrine's second real exercise: reachability *is* the
authorization, so the reachability graph is exactly the tenancy graph. Contrast with ADR-0024
deliberately: Grafana got org-isolation *behind a shared entrypoint* because humans need one
URL; workload telemetry needs no shared entrypoint, so it gets the stronger cut. Human access
to the Phoenix UI is per-tenant port-forward locally; a real per-tenant URL with auth is the
ingress story's problem (ADR backlog), not solved prematurely here.

**D27-3. Plaintext-in-traces is contained, not encrypted.** Each instance holds only its own
tenant's conversation content, inside the tenant boundary D27-2 draws — the same containment
argument as the tenant's own Postgres. D16-5 protects the *shared* history store; there is no
shared trace store to protect. Storage is `emptyDir` (the D24-1 posture: nothing precious on
the observability plane's disks; traces are diagnostics — Temporal's encrypted history is the
system of record). A tenant whose compliance regime needs durable, exportable traces gets a
PVC/managed backend at activation — register row.

**D27-4. Delivery reuses the `TEMPORAL_*` pattern unchanged.** The renderer stamps
`PHOENIX_COLLECTOR_ENDPOINT` (the tenant's own instance, `/v1/traces`) on every agent-unit
container. Both apps already read exactly this variable and fail-soft when it's unset, so
delivery is always safe: apps without OTLP ignore it, apps with it start exporting. No
registry schema change — the instance is implied by having agent-units, the same way Temporal
env vars are. At activation the value changes (managed collector / per-tenant URL), the
variable doesn't — the `IMAGE_REGISTRY`/`TEMPORAL_ADDRESS` migration story again.

**D27-5. The ownership boundary grows one explicit clause, not an exception list.**
`gitops/platform/` is renderer-generated platform-plane infra; the D12-3 guard now admits
NetworkPolicy/ServiceAccount there **only when namespaced to `platform-system`** — a namespace
Terraform never manages, so dual ownership stays impossible by construction. The same kinds
aimed at a tenant namespace from the rendered tree are still refused (that would be the
original ADR-0012 bug). The renderer also refuses half-overridden output-dir test hooks, since
both trees are pruned on render.

**License note (flagged for the day tenants are external parties).** Phoenix is under the
**Elastic License 2.0**, not Apache: free to self-host and run per-tenant internally — so
per-tenant instances genuinely cost only compute/memory (~256Mi–1Gi each), no license fees —
but ELv2 restricts *providing the software to third parties as a managed service*. A platform
whose tenants are internal teams is clearly fine; a platform selling hosted Phoenix URLs to
external customers should have that reading checked by someone qualified before activation.
Recorded here so the question is asked once, deliberately, not discovered later.

## Consequences

- App-side handoff owed (coordinated, not unilateral): evict the Phoenix service from
  `customer-service-agent`'s compose stack, drop `ai-employees-core`'s cross-stack
  `host.docker.internal` wiring; both apps keep compose-local Phoenix only for laptop-only
  development if they want it. The platform contract is just the env var.
- Not built, gated: per-tenant Phoenix **auth** (instances currently trust network
  reachability alone — acceptable while the netpol is the boundary and the UI needs
  port-forward; revisit with the ingress story); durable trace storage (D27-3, activation);
  Phoenix as a registry opt-*out* if a tenant ever wants no tracing.
- Register: new row for the activation half (durable storage, per-tenant URLs + auth via the
  ingress story, the ELv2 reading, GKE-side image pull of a 1GB third-party image).
- Live verification (same session, results in VERIFICATION.md): instance Ready via Config
  Sync; reachable from the tenant's own pod; unreachable from a non-tenant namespace; real
  traces from the deployed workloads if the images honor the env var.
