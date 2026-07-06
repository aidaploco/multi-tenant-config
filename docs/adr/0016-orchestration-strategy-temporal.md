# ADR-0016: Orchestration strategy — Temporal for agentic workloads

- **Status:** Accepted (2026-07-06). The "second look" at the hosting/vendor decision is
  recorded as D16-5/D16-6: Temporal Cloud stands, **with payload encryption non-negotiable**
  and the namespace-count math a verification gate before fleet-scale onboarding.
- **Date:** 2026-07-06
- **Builds on:** ADR-0002 (agent-unit archetype), ADR-0010 (Composer), ADR-0015 (shared-compute
  isolation — its "enforced, not assumed" lesson drives D16-2 here).
- **Amends:** ADR-0010's implied scope (Composer as *the* orchestration plane).

---

## Context

Agentic workloads need **durable execution**: conversations and tool-call chains that survive
pod restarts, retry over hours or days, and pause for humans. Temporal is the leading answer,
and it is two different things at once:

- **The SDK** (Python `temporalio`): workflows/activities/worker code. Application-side —
  lives in the workload repos, not here.
- **The Temporal Service**: a server cluster (frontend/history/matching/worker services) + a
  persistence database that durably stores every workflow's event history and dispatches tasks.
  It never runs workload code — *our* workers do. This half is a **shared orchestration control
  plane**, the same class of thing as Composer, so its tenancy model is a platform decision.

Meanwhile ADR-0010 gave us Composer as the orchestration plane, and ADR-0015 documented that
making *shared Airflow* safe for tenants requires enforcement work (per-tenant connections,
Airflow RBAC, exact-KSA constraints) that is tracked but unbuilt. Composer is also the
platform's most expensive module (~$300–400/mo per env) and entirely unverified live. Running
two orchestrators without a written role split is how platforms grow two half-secure ones.

## Options

### A. Which orchestrator owns what

| Option | Consequence |
| ------ | ----------- |
| Airflow for everything (status quo) | Wrong tool for agents: no durable per-conversation state, scheduled-DAG model fights event-driven work; drags the full ADR-0015 enforcement backlog into the agent path. |
| Temporal for everything | Plausible endgame, but batch data pipelines (when they arrive) are Airflow's home turf and the data team's lingua franca. |
| **Split: Temporal = agentic/event-driven durable work; Airflow = scheduled batch data pipelines** | Each tool where it's strong; Composer stays parked until a real data-pipeline tenant needs it. **Chosen.** |

### B. How the Temporal Service is hosted

| Option | Isolation | Ops | Cost shape |
| ------ | --------- | --- | ---------- |
| **Temporal Cloud** | Per-tenant **namespace** with its own credential + metering — isolation is a product feature we buy | None | Consumption (per action) + per-namespace billing ⇒ per-tenant cost attribution for free |
| Self-hosted OSS on the runtime cluster | **OSS ships with NO authn/authz.** Stopping tenant A's worker from opening tenant B's namespace means writing and policing a custom ClaimMapper/Authorizer + per-namespace rate limits — the exact "isolation by discipline" failure mode ADR-0015 exists to prevent | 4 services + Postgres + visibility store, upgrades, on-call | Infra + our time |

## Decision

1. **D16-1 — Role split.** Temporal owns agentic/event-driven durable orchestration. Airflow
   (Composer) owns scheduled batch data pipelines **only**, and stays parked — not extended, not
   made multi-tenant-safe — until a data-pipeline tenant actually arrives. The ADR-0015 tracked
   follow-ons (per-tenant Airflow connections/RBAC) are **deferred with it**, not deleted.
2. **D16-2 — Temporal Cloud, not self-hosted, for any real environment.** The deciding argument
   is ADR-0015's own lesson: shared-control-plane isolation must be *enforced, not assumed*, and
   with OSS we would have to build the enforcement ourselves (custom ClaimMapper on a component
   with no built-in auth). We buy it instead. Self-hosting is the documented graduation if
   cost/action volume or data-residency ever demands it.
   **Local/dev exception:** the OSS dev server runs beside the kind cluster for the local demo —
   free, zero cloud, and exercises the same SDK code paths.
3. **D16-3 — Tenancy mapping (the platform's half).** One Temporal **namespace per
   (tenant, environment)**, provisioned data-driven from the registry via the official
   `temporalio/temporalcloud` Terraform provider (v1.5.0, 2026-05) — a thin `temporal-namespace`
   platform module, exactly analogous to `kms-tenant`. Task queues are per (tenant, unit),
   declared on the unit in the registry YAML. **Workers are ordinary agent-unit pods**: deployed
   by the workload delivery path into the tenant's k8s namespace, running as the tenant's WI SA.
   Per-namespace credentials (API key / mTLS) live in Secret Manager under the tenant's CMEK.
4. **D16-4 — Build triggers.** This ADR now; the `temporal-namespace` module + registry schema
   fields when the **first workload consumes them** (the customer-service-agent integration);
   nothing before. No self-hosted Temporal in any shared environment, ever, without a
   superseding ADR.
5. **D16-5 — Payload confidentiality (closes the CMEK gap).** Temporal durably persists every
   workflow's event history — for agentic work that is **conversation content and tool-call
   results**, landing in Temporal Cloud's persistence *outside* the platform's CMEK boundary.
   Unaddressed, this is a silent exception to "CMEK is mandatory, fail closed." Therefore:
   the SDK **Data Converter / payload codec encrypts client-side** before anything leaves the
   worker — keys from the tenant's `kms-tenant` keyring, so Temporal Cloud stores ciphertext
   only; large artifacts pass **by reference** (GCS URI in the tenant's bucket), never by
   value; and codec config is a fail-closed requirement of the worker deployment (gated with
   D16-4 — the codec ships with the first workload, the key/IAM half is the platform's).
   **Known plaintext residue:** search attributes, memo fields, and workflow IDs bypass the
   codec and stay visible in visibility storage — they carry opaque IDs only, never message
   text, names, or emails.
6. **D16-6 — Scale check + observability, before fleet rollout.** Namespace-per-(tenant, env)
   must be re-verified against Temporal Cloud's **current per-namespace floors and account
   namespace limits** before onboarding beyond the first tenants — at PLAN-scale (80 tenants ×
   3 envs = 240 namespaces) the pricing shape may differ from the pilot. Documented
   degradation path if the floors bite: namespace per **tenant**, with environment as a
   task-queue prefix + search attribute for non-prod. Temporal Cloud **metrics export wires
   into the observability module** (alerts fire to the same channels as the rest of the
   fleet); workflow histories double as the raw material for per-tenant task success /
   escalation / retry metrics — the same attribution story as D16-3's per-namespace metering.

## What stays application-side (explicit non-goals here)

Workflow/activity definitions, worker entrypoints, retry/timeout policies, SDK versions —
all of it belongs to the workload repos. The platform provisions the namespace, the identity,
the credential, and the worker's deployment; it never sees workflow code.

## Consequences

- The agent path gets durable execution without inheriting the Airflow-isolation backlog;
  Composer's cost and its ADR-0015 enforcement work are deferred until a data tenant exists.
- **Parked is enforced in code, not prose:** the runtime root gates the `cloud-composer` module
  behind `composer_enabled` (default `false`) — no Composer environment, CIDRs stay reserved,
  the module stays versioned in platform-modules, and one flag is the whole re-activation path.
- A new external vendor + consumption spend, mitigated by per-namespace metering (which also
  gives per-tenant orchestration cost attribution — the same attribution story as D15's
  budgets).
- The registry schema will grow unit-level task-queue fields (schema change gated on D16-4).
- New verification-register entries when built: namespace provisioning via the TF provider,
  credential issuance, worker connectivity from a tenant namespace, **codec round-trip under
  the tenant's CMEK key, and the metrics-export scrape** (D16-5/D16-6).
- Temporal Cloud never holds plaintext conversation data (D16-5) — which also keeps the
  regulated-vertical story (reinsurance/brokerage/wealth) intact without VPC-SC-class work.
- The kind-based local demo gains a Temporal dev server — durable agent workflows demoable
  with zero cloud.
