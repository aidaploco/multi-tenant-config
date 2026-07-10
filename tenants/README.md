# tenants/ — the tenant registry (schema v2)

**One YAML file per tenant. This is the entire onboarding interface.** Adding a tenant is one
file + one PR; the Terraform root (`terraform/tenants/`) reads *every* file here and loops with
`for_each`. No per-tenant directories, no copy-paste, no code generation — that was the single
biggest failure mode in the platform this design learns from.

Schema v2 is defined in [ADR-0002](../docs/adr/0002-two-axis-tenancy-and-schema-v2.md) (amended by
[ADR-0011](../docs/adr/0011-fleet-wide-platform-versioning.md)). It adds **per-environment**
configuration and **axis-2 scale units** to the original flat schema.

## Shape

```yaml
slug: abf                              # short id; project prefix + label value; [a-z0-9-]
display_name: "ABF Analytics"
owner_group: abf-data-engineers@company.com
data_classification: confidential      # internal | confidential | restricted  (drives D14)
cmek_location: europe-west4            # KMS location for this tenant's CMEK keys

defaults:                              # baseline; each environment overrides per key
  budget_usd: 5000                     # billing ALERTS, not a hard cap
  layers:                              # axis 1 — the substrate (one of each)
    storage:   { opt_in: true }
    ingestion: { opt_in: true }
    bigquery:  { opt_in: true }
    compute:   { opt_in: true,  isolation: shared }   # shared|dedicated
    composer:  { opt_in: false, isolation: shared }
  units: {}                            # axis 2 — workloads (0..N), see below
  feature_flags: {}

environments:                          # a MAP now; tenant exists in exactly these keys
  dev:
    units:
      search-a: { type: agent-unit, version: 1.4.0, opt_in: true }
  acc: {}                              # {} = take all defaults
  prod:
    budget_usd: 8000                   # overrides default for prod only
    units:
      search-a: { type: agent-unit, version: 1.3.0, opt_in: true }
```

## Field reference

| Field | Type | Meaning |
| ----- | ---- | ------- |
| `slug`, `display_name`, `owner_group` | string | Identity; same in every environment. |
| `data_classification` | enum | `internal` \| `confidential` \| `restricted`. Drives compute isolation. |
| `cmek_location` | string | KMS location for the tenant's CMEK keys. |
| `defaults` | object | Baseline `budget_usd` / `layers` / `units` / `feature_flags` for all environments. |
| `environments` | **map** | Keys are the environments the tenant exists in. Each value **shallow-merges** over `defaults`. |
| `layers.<name>` | object | `{ opt_in: bool, isolation?: shared\|dedicated }`. **No version** — platform-module versions are fleet-wide in [`VERSIONS.md`](../VERSIONS.md), not per-tenant (ADR-0011). |
| `units.<name>` | object | `{ type: <archetype>, opt_in: bool, version?: <app release>, image?: <repo name>, task_queue?: <name>, port?: <int>, expose_port?: bool, command?: [<string>], secret_ref?: <k8s Secret name>, manifest_ref?: <k8s ConfigMap name>, packs_ref?: <k8s ConfigMap name>, feature_flags?: map, overrides?: map }`. `version` is the workload's *app* release, not a platform version — for an **opted-in agent-unit it is REQUIRED**: it is the deployed image tag (ADR-0017). `image` overrides the image repo name when it differs from the unit name (default: the unit name). `task_queue` is the Temporal task queue an agent-unit's worker polls (ADR-0016 D16-3, default: the unit name) — the platform delivers it as an env var; it does not create the queue (queues are implicit in Temporal, created by first use). `port` is the container's listen port (default `8080`) — only meaningful when `expose_port` is true. `expose_port` (default `true`): set `false` for a **headless** unit (e.g. a Temporal worker with no HTTP surface) — no `containerPort`, no Service rendered. `command` overrides the image's own entrypoint/CMD — lets one image serve two roles (e.g. an API unit and a worker unit sharing one build). `secret_ref` (default: the unit name) names a k8s Secret, pre-created by a human (never the registry — see ADR-0020), whose keys are injected as env vars via an *optional* `envFrom` — a missing Secret does not block the pod from starting. `manifest_ref`/`packs_ref` (ADR-0021, unset by default — only wired up when declared) each name a k8s ConfigMap, pre-created by a human/CI (content, not secrets — but not GitOps-tracked yet, a known gap), mounted as a volume and exposed via `MANIFEST_PATH`/`PACKS_DIR` env vars — `manifest_ref`'s ConfigMap must have a key literally named `manifest.yaml`. |

## Two axes (ADR-0002)

- **Layers** = the substrate, one of each, ordered. (Toggle with `opt_in`.)
### Unit archetypes & their `overrides`

| `type` | Built? | `overrides` it understands |
| ------ | ------ | -------------------------- |
| `agent-unit` | ✅ | `iam_roles: [<role>, …]` — least-privilege grants for the unit's runtime identity. Primitive (`owner`/`editor`/`viewer`) and SA-key roles are rejected. |
| `data-unit` | ⏳ | buckets/BQ/Pub/Sub/secrets (follows agent-unit's shape) |
| `app-unit` | ⏳ | compute workload on the shared runtime |

Example agent-unit with a grant:

```yaml
units:
  search-a:
    type: agent-unit
    version: 1.4.0
    opt_in: true
    task_queue: search-a-queue   # optional — default: the unit name ("search-a")
    overrides:
      iam_roles: [roles/storage.objectViewer]
```

One image, two roles — an HTTP API unit and a headless Temporal worker unit sharing a task
queue and a Secret (ADR-0020):

```yaml
units:
  cs-agent-api:
    type: agent-unit
    version: 0.2.0
    image: cs-agent-backend       # both units pull the same image
    opt_in: true
    task_queue: cs-agent          # MUST match the worker unit's — one queue, two enqueue/poll sides
    port: 8000
    secret_ref: cs-agent-secrets  # both units share one pre-created Secret
  cs-agent-worker:
    type: agent-unit
    version: 0.2.0
    image: cs-agent-backend
    opt_in: true
    task_queue: cs-agent
    command: ["python", "-m", "durable.worker"]
    expose_port: false            # headless — no containerPort, no Service
    secret_ref: cs-agent-secrets
```

- **Units** = workloads on top, `0..N`. Archetypes: `data-unit`, `app-unit`, `agent-unit`.
  `agent-unit` is built and **provisions** (a runtime identity); `data-unit`/`app-unit` follow.
  Units deploy *inside the shared per-environment composition* (one state per env); independent
  per-unit state is a documented future graduation (ADR-0004), not built now.

## Versioning (ADR-0011)

- **Platform-module versions are fleet-wide** — one source of truth, [`VERSIONS.md`](../VERSIONS.md).
  Every tenant runs the same module versions; a bad module rolls back fleet-wide (caught in dev
  first). The registry carries **no** per-tenant module version. Per-tenant divergence is the rare
  held-back-tenant exception = the generator graduation, deliberately not a default.
- **A unit's `version`** is its *app* release, and since ADR-0017 it is load-bearing: for an
  opted-in `agent-unit` it is the **image tag the delivery path deploys**
  (`gitops/payload/<env>/<tenant>/<unit>.yaml`, rendered by `scripts/render-payload.rb`).
  Promoting a release to prod = a PR bumping prod's `version` + re-render. It is *not* a
  platform-module pin.

## What is enforced today

- Per-environment existence, layer `opt_in`, the `restricted → dedicated` guardrail (compute *and*
  composer), and unit validation (unknown `type` fails the plan).
- By the renderer (CI, ADR-0017): an opted-in `agent-unit` must pin a `version` (never `latest`),
  and a `restricted` tenant may not declare one at all (no shared-plane delivery for regulated
  data); `gitops/payload/` must match the registry (re-render check).

## `data_classification` drives compute isolation (ADR-0001 D14)

- `internal` / `confidential` → compute **may be `shared`** (namespace-isolated on the shared
  runtime plane — far cheaper).
- `restricted` → compute **must be `dedicated`** (regulated data may not share infrastructure).
  A `restricted` tenant with `isolation: shared` on compute or composer fails the plan.

## Examples

- [`abf.yaml`](abf.yaml) — `confidential`, shared compute, dev/acc/prod, dev runs a unit ahead of prod.
- [`helix.yaml`](helix.yaml) — `restricted`, dedicated compute + composer, dev + prod only.
