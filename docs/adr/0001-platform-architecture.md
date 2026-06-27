# ADR-0001: Foundational Architecture for the Multi-Tenant GCP Data Platform

- **Status:** Accepted
- **Date:** 2026-06-27
- **Deciders:** Platform team (Aida + 2 engineers)
- **Supersedes:** none
- **Superseded by:** none

---

## How to read this document

This is the foundational Architecture Decision Record for the platform. It is written to
be **read by a future engineer (or your future self) who was not in the room**, so it
explains the *why* behind each choice and the **failure mode it avoids**, not just the
choice itself.

Each decision is tagged with its origin:

- **`[Proposal]`** — came from the original design proposal; accepted as-is.
- **`[Revised]`** — the proposal addressed this, but we changed it during review.
- **`[New]`** — not in the proposal; added during review.

Later, narrower decisions get their own ADRs (`0002-…`, `0003-…`). This one records the
load-bearing foundations. If a future decision contradicts something here, it must
supersede this ADR explicitly, not silently.

---

## Context

We are building a **multi-tenant data platform on GCP** for a small engineering
organisation. The defining constraints:

- **Team size: 3 engineers.** Every choice is weighed against operational burden. We buy
  managed services rather than running infrastructure ourselves.
- **Scale: 20–80 tenants (clients), each across dev / staging / prod.** Onboarding tenant
  #50 must be as cheap as tenant #2.
- **Security and tenant isolation are non-negotiable.** Tenant A must never be able to
  read or reach Tenant B's data.
- **This design is based on a lessons-learned review of a real production Azure platform.**
  Several decisions exist specifically to avoid that platform's known failure modes
  (a code-generation engine, a per-tenant pipeline factory, five repositories kept in sync
  by tooling, service-account key sprawl, and private networking deferred to "phase 2").

Terminology used throughout (defined once here):

| Term | Plain meaning |
|---|---|
| **Tenant** | A client we serve; gets isolated infrastructure. |
| **GCP project** | A cloud resource container that is also a billing and permissions boundary. |
| **Terraform** | Tool that defines cloud infrastructure as version-controlled text files. |
| **Module** | A reusable Terraform building block (e.g. "a bucket done the right way"). |
| **Terragrunt** | A thin wrapper around Terraform that reduces repetition and isolates state. |
| **CMEK** | Customer-Managed Encryption Key — a tenant's data encrypted with their own key. |
| **WIF / Workload Identity** | Keyless authentication using short-lived tokens instead of key files. |
| **OPA** | Open Policy Agent — an automated rule-checker that runs before changes are applied. |
| **Org Policy** | An org-wide rule the cloud itself refuses to violate at runtime. |
| **VPC** | The private internal network resources run on. |
| **VPC-SC** | VPC Service Controls — a perimeter that stops data being copied *out* of a project. |
| **DAG** | Directed Acyclic Graph — "boxes with arrows"; how a pipeline is defined in Airflow. |

---

## Decisions

### D1. Two repositories, mapped onto the two repos that already exist `[Proposal]`

We use **exactly two repositories**, not a monorepo and not five:

- **`platform-modules`** → the existing `multi-tenant-platform` repo. Reusable, **versioned**
  Terraform modules. Platform team owns it. Consumers pin to a git tag (e.g. `v1.4.2`),
  never to `main`. Contains no tenant-specific or environment-specific values.
- **`platform-config`** → the existing `multi-tenant-config` repo. The tenant registry,
  per-tenant config, CI/CD pipelines, OPA policies, and this ADR. The **only** repo tenant
  teams ever touch.

**Why:** Two repos let us version the building blocks independently of their use, and keep
tenant teams out of platform internals. **Failure mode avoided:** the reference platform
used five repos and needed a code-generation engine just to keep them synchronised — the
single largest source of its complexity. A monorepo has the opposite problem: tenant teams
get write access to platform code, and modules can't be versioned independently.

**Not using git submodules.** `platform-config` consumes modules by pinned tag reference.

### D2. Isolation boundary = one GCP project per tenant, per environment `[Proposal]`

Every tenant gets **one GCP project per environment**. Folders are used only for policy
inheritance, never for isolation. The project is the billing boundary, the IAM boundary,
and the API-enablement boundary simultaneously.

**Why:** This is the strongest practical isolation GCP offers short of separate
organisations. Each tenant gets the equivalent of their own apartment with its own lock and
its own utility meter, not a drawer in a shared room. ~80 tenants × 3 environments ≈ **240
projects**, all created automatically by code.

**Note (data plane vs compute plane):** D2 governs the **data plane** — the resources that
*hold data* (storage, databases, analytics, messaging, keys, secrets, logs). Those stay
strictly one-per-tenant-project. The **compute plane** (the runtime that *processes* data)
is shared under controlled conditions — see **D13**.

### D3. Multi-tenancy is data-driven: one YAML file per tenant `[Proposal]`

There is exactly one tenant definition file per tenant: `tenants/<slug>.yaml`. The Terraform
root reads **all** of them and loops. Adding a tenant = **one YAML file + one pull request**.
No new directories, no copy-paste, no code generation.

**Why:** This is the single most important decision in the platform. **Failure mode avoided:**
the reference platform copy-pasted a directory per tenant and needed a generator to keep 60+
duplicated files in sync — two sources of truth and debugging-by-archaeology. The analogy
from ML: config-driven experiments instead of a hand-edited script per run.

Minimum tenant schema (extended in D14):

```yaml
slug: abf
display_name: "ABF Analytics"
owner_group: abf-data-engineers@company.com
environments: [dev, staging, prod]
layers:
  storage: true
  ingestion: true
  bigquery: true
  compute:                    # see D13/D14
    enabled: true
    isolation: shared         # shared | dedicated (defaulted from data_classification)
  composer:
    enabled: false
    isolation: shared
cmek_location: europe-west4
budget_usd: 5000
data_classification: confidential   # internal | confidential | restricted — drives D14
```

### D4. Private by default, enforced from day zero `[Proposal]`

Every resource is private from the moment it is created. No public IPs (blocked by Org
Policy with an empty allowlist), Private Google Access on every subnet, Private Service
Connect for managed APIs, and a VPC-SC perimeter wrapping tenant projects before any data
resource exists.

**Why / failure mode avoided:** "We'll add private networking in phase 2" creates security
debt that is nearly impossible to repay without downtime. An Org Policy that blocks public
IPs from day zero means a public resource **cannot be created by accident**, ever.

### D5. Keyless identity everywhere `[Proposal]`

No service-account JSON keys. Ever. Enforced by Org Policy
(`iam.disableServiceAccountKeyCreation`). Workloads authenticate with **Workload Identity**;
CI/CD authenticates with **Workload Identity Federation** (GitHub OIDC); cross-project access
uses impersonation. All tokens are short-lived (≈1 hour).

**Why / failure mode avoided:** A leaked long-lived credential is the single most common
cloud breach. If there is no downloadable key, there is nothing to leak. This also
eliminates an entire class of key-rotation work (see D7 / Phase 7).

### D6. CMEK on every stateful resource, per tenant, with native rotation `[Proposal]`

Each tenant gets its own KMS keyring in a **separate key-management project** (separation of
duties), with one key per service type, auto-rotating every 90 days using the **native** GCP
feature. Modules require an explicit `cmek_key_id`; passing `null` fails a precondition
rather than silently using Google-managed keys.

**Why / failure mode avoided:** Per-tenant keys mean even our own engineers cannot read a
tenant's data without going through that tenant's key. Forcing the key to be explicit
prevents "accidentally unencrypted." Native rotation avoids the reference platform's fragile
cron-job rotation pipeline.

### D7. Everything as code, with a module versioning contract `[Proposal]`

All infrastructure is Terraform, reviewed in pull requests. `platform-modules` uses
semantic-release (conventional commits → auto-tagged versions). `platform-config` always
pins to a specific tag (`?ref=v1.4.2`), never `main`. A `VERSIONS.md` in `platform-config`
is the single source of truth for what is deployed; a CI check enforces that it matches the
refs actually used.

**Why:** Pinning is the stability contract — upgrading a module is a deliberate PR, not an
accident of someone pushing to `main`.

### D8. Policy as code (pre-flight) + Org Policy (runtime) `[Proposal]`

**OPA/Conftest** runs in CI against every Terraform plan and **blocks** changes that violate
the rules (no public IPs, CMEK required, keyless required, approved regions only, required
labels present, destroy-count under a threshold). **Org Policy** is the runtime backstop the
cloud enforces regardless. A plan that fails policy never reaches apply — not even in dev.

**Why:** Two independent layers — a tireless robotic reviewer before, and a hard runtime
floor after.

### D9. Environment promotion is enforced, not conventional `[Proposal]`

Pipeline: PR → plan (all envs) → OPA gate → merge → **auto-apply dev** → manual approval →
**staging** → manual approval → **prod**. The approval gates are GitHub Environment
protection rules with required reviewers, enforced by the CI system, not a team norm.

### D10. CI/CD runner: GitHub Actions only — drop Atlantis / Terraform Cloud `[Revised]`

The proposal contradicted itself: Part 2 said "use Atlantis OR Terraform Cloud, do not
hand-roll plan/apply in Actions," then specified a hand-rolled Actions pipeline in detail.

**Decision:** **GitHub Actions owns plan and apply directly.** No Atlantis, no Terraform
Cloud. **Why:** For a 3-engineer team, a separate Terraform-runner service is moving parts
we'd have to operate and secure for little benefit, and our custom gates (OPA, destroy-count
threshold) are easier to wire inline. Pick one tool and own it well.

### D11. State layout: Terragrunt with per-tenant generated roots `[Revised]`

The proposal waffled between Terraform workspaces and Terragrunt, and its tenant loop had a
**technical flaw**: it wanted to `for_each` over tenants *and* give each tenant its own
provider connection. Terraform cannot do both — a `provider` block can't be `for_each`-ed,
and a module's providers must be statically known.

**Decision:** Use **Terragrunt to generate one isolated root per tenant per environment**,
each with its own provider/impersonation and **its own state file**.

**Why this fixes two problems at once:**
1. **Provider-per-tenant** becomes natural (each generated root has its own).
2. **Blast radius:** one tenant's bad YAML, quota error, or API hiccup fails only *that*
   tenant's plan/apply, not the whole fleet. **Failure mode avoided:** a single shared state
   file for 20–80 tenants means one tenant can jam everyone's deployments — and our target
   scale already exceeds the "split it" threshold the proposal itself cites.

### D12. Split CI identity: read-only planner vs write applier `[Revised]`

The proposal had **one** CI service account holding org-level admin powers
(`projectCreator`, `folderAdmin`, `orgpolicy.policyAdmin`, `organizationRoleAdmin`), and its
WIF trust was bound to the repository with **no branch condition** — so any pull-request
branch could borrow an org-admin identity and run untrusted code (provider plugins, data
sources) as org-admin. That is a privilege-escalation path to org admin.

**Decision (the most important security correction in this ADR):**
- A **planner** SA: read-only (viewer + read). Assumable from **any PR branch**. Runs `plan`.
- An **applier** SA: write access. Assumable **only from `refs/heads/main`**. Runs `apply`.
- WIF providers are conditioned on `ref` accordingly.

**Why:** Untrusted PR code can now only ever *look*, never *change*, and the powerful
identity is unreachable except from the trusted, already-reviewed main branch.

### D13. Shared compute plane in `runtime-<env>` projects `[Revised]`

The proposal gave each tenant their own **Cloud Composer** (managed Airflow) and **GKE**
(managed Kubernetes). At 80 tenants × 3 envs that is **240 Composer environments**, each
costing ≈ $400/month *just to exist* → **≈ $100,000/month of idle cost** before a single
pipeline runs. No budget knob fixes an 80× structural multiplier.

**Decision:** Composer and GKE Autopilot move into **shared, platform-owned `runtime-<env>`
projects** (one per environment, 3 total each). A tenant's `compute` / `composer` flag now
means *"a namespace + Workload Identity SA + DAG folder + resource quota inside the shared
runtime,"* **not** *"a new cluster."* This takes fixed cost from `O(tenants × envs)` to
`O(envs)`.

**The principled line:** the **data plane stays strictly per-tenant-project** (D2). Only the
**compute runtime** is shared. The sensitive bytes keep their hard, audited boundary; only
ephemeral processing shares space.

**Mandatory isolation controls** (non-optional, treated like "no public IP"):
- *Shared GKE:* default-deny `NetworkPolicy` per namespace; per-namespace Workload Identity
  SA; `ResourceQuota` + `LimitRange`; Gatekeeper constraints; namespace-scoped RBAC.
- *Shared Composer/Airflow:* per-tenant DAG folders + Airflow RBAC; task execution via
  `KubernetesPodOperator` running as the **tenant's** WI SA (so a task can only touch its own
  tenant's data); per-tenant connections/variables; Airflow pools + quotas to prevent a
  noisy neighbour starving the scheduler.

**Residual risk (accepted, and the reason D14 exists):** in shared Composer the metadata DB,
scheduler, and webserver are a shared trust zone — a hostile or buggy DAG can degrade
*scheduling* for everyone (it cannot read another tenant's data, because of the per-task WI
SA). This is the conscious trade we buy for ≈ $100k/month.

### D14. Share-vs-dedicate routed by `data_classification`; cutoff = `restricted` only `[New]`

`data_classification` is a **business** decision (how bad is a leak?), set by contract or
regulation, not chosen freely by the tenant:

| Tier | Meaning | Compute placement |
|---|---|---|
| `internal` | Not sensitive | **Shared** runtime |
| `confidential` | Business-sensitive / PII (most tenants) | **Shared** runtime |
| `restricted` | Legal/regulatory teeth (HIPAA, PCI, etc.) | **Dedicated** Composer/GKE in tenant project |

**Decision:** Only **`restricted`** tenants get dedicated compute; `internal` and
`confidential` share (D13). **Why this is the right line:** for shared tenants the realistic
worst case is a noisy-neighbour scheduling problem, *not* a data breach (per-task WI SA still
isolates data access). For `restricted`, the compliance paper typically forbids shared
infrastructure outright — so dedicated isn't caution, it's contract compliance. The cutoff is
drawn by what regulators care about, which is the only principled place to draw it.

**Build strategy — "build the seam now, build the second path when the first case arrives":**
the `isolation: shared | dedicated` YAML knob exists from day one (the seam), but we **only
implement the shared path** initially, because we expect zero `restricted` tenants at launch.
The day a `restricted` client signs, the dedicated path is a feature PR, not a redesign.

### D15. Cost model `[New]`

Order-of-magnitude planning figures (list price, not quotes; for relative reasoning):

| Cost class | Per-tenant-dedicated (proposal) | Shared model (this ADR) |
|---|---|---|
| Composer control plane | ≈ $400 × tenants × envs (≈ $100k/mo @ 80×3) | ≈ $400 × **envs** (≈ $1.2k/mo) |
| GKE cluster management fee | ≈ $73 × tenants × envs (≈ $17k/mo) | ≈ $73 × **envs** (≈ $0.2k/mo) |
| GCS / BigQuery / Cloud SQL / Pub/Sub / logs / Prometheus | per-tenant (**unchanged**) | per-tenant (**unchanged**) |

Sharing collapses the *fixed* control-plane cost; it deliberately does **not** reduce the
per-tenant data plane (that is where isolation lives and must stay). `budget_usd` in the YAML
drives **billing alerts only** — GCP budgets do not hard-cap spend, so runaway-tenant
quarantine is a separate operational control to design.

---

## Consequences

**What this makes easy:**
- Onboarding a tenant is one YAML file + one PR (D3).
- A leaked key is impossible (D5); accidental public exposure is impossible (D4).
- One tenant's failure is contained to that tenant (D11).
- The platform is financially viable at 80 tenants (D13–D15).

**What this makes harder / what we accept:**
- **VPC-SC operational cost** — once a tenant project joins a perimeter, the CI applier SA
  must be in an ingress rule or every later apply breaks; perimeter changes are slow and can
  lock you out. We will dry-run perimeters first and treat the CI ingress policy as
  first-class. *(This is the most underestimated ongoing cost for a 3-person team.)*
- **East-west network isolation** — a single shared host VPC means tenant projects share L3/L4
  space; VPC-SC governs data exfiltration, **not** traffic between tenants. We require
  per-tenant default-deny firewall policy as part of the `shared-vpc` module (or split the VPC
  per classification tier). *To be settled in a networking ADR before Phase 2.*
- **Shared Airflow trust zone** — accepted for non-`restricted` tenants (D13/D14).

**Deferred to their own ADRs / runbooks (not in scope here, but flagged so they aren't
forgotten):**
- Tenant **offboarding** (removing a YAML = destroying a tenant; collides with the
  destroy-threshold policy — needs a safe teardown + data-retention flow).
- **Break-glass** emergency procedure (if CI is the only mutate path, what is the audited
  human override?).
- **OPA policy single-sourcing** (publish from `platform-modules` by version; don't duplicate
  into `platform-config`).
- **State disaster recovery** (versioning ≠ backup).

---

## Open question carried forward

The dedicated/shared cutoff (D14) is set at **`restricted` only**. If a future contract
requires `confidential` tenants to be dedicated too, that is a one-line policy change plus
the dedicated-path implementation — record it as a superseding ADR.

## Next steps

1. This ADR is the first artifact in `platform-config`. ✅
2. **Phase 0 — Bootstrap** (mostly manual, one time): org, folders, management project,
   Terraform state bucket, the split planner/applier SAs (D12), WIF pool with branch
   conditions, day-zero Org Policies (D4/D5).
3. **Phase 1 — `platform-modules`**: build the module library bottom-up
   (`gcp-project` → `kms-tenant` → `shared-vpc` → …).

Subsequent decisions (networking/firewalls, offboarding, break-glass, observability
thresholds) get their own numbered ADRs.
