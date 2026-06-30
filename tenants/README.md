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
| `units.<name>` | object | `{ type: <archetype>, opt_in: bool, version?: <app release>, feature_flags?: map, overrides?: map }`. `version` is the workload's *app* release (optional), not a platform version. |

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
    overrides:
      iam_roles: [roles/storage.objectViewer]
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
- **A unit's `version`** is its *app* release (optional, archetype-specific). `agent-unit` is pure
  identity and has none; it becomes meaningful for workload archetypes (app-unit). It is *not* a
  platform-module pin.

## What is enforced today

- Per-environment existence, layer `opt_in`, the `restricted → dedicated` guardrail (compute *and*
  composer), and unit validation (unknown `type` fails the plan).

## `data_classification` drives compute isolation (ADR-0001 D14)

- `internal` / `confidential` → compute **may be `shared`** (namespace-isolated on the shared
  runtime plane — far cheaper).
- `restricted` → compute **must be `dedicated`** (regulated data may not share infrastructure).
  A `restricted` tenant with `isolation: shared` on compute or composer fails the plan.

## Examples

- [`abf.yaml`](abf.yaml) — `confidential`, shared compute, dev/acc/prod, dev runs a unit ahead of prod.
- [`helix.yaml`](helix.yaml) — `restricted`, dedicated compute + composer, dev + prod only.
