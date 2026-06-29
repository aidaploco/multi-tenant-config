# tenants/ — the tenant registry (schema v2)

**One YAML file per tenant. This is the entire onboarding interface.** Adding a tenant is one
file + one PR; the Terraform root (`terraform/tenants/`) reads *every* file here and loops with
`for_each`. No per-tenant directories, no copy-paste, no code generation — that was the single
biggest failure mode in the platform this design learns from.

Schema v2 is defined in [ADR-0002](../docs/adr/0002-two-axis-tenancy-and-schema-v2.md). It adds
**per-environment** configuration and **axis-2 scale units** to the original flat schema.

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
    storage:   { opt_in: true,  version: 0.1.0 }
    ingestion: { opt_in: true,  version: 0.1.0 }
    bigquery:  { opt_in: true,  version: 0.1.0 }
    compute:   { opt_in: true,  version: 0.1.0, isolation: shared }   # shared|dedicated
    composer:  { opt_in: false, version: 0.1.0, isolation: shared }
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
| `layers.<name>` | object | `{ opt_in: bool, version: <semver>, isolation?: shared\|dedicated }`. |
| `units.<name>` | object | `{ type: <archetype>, version: <semver>, opt_in: bool, feature_flags?: map, overrides?: map }`. |

## Two axes (ADR-0002)

- **Layers** = the substrate, one of each, ordered. (Toggle with `opt_in`.)
- **Units** = workloads on top, `0..N`. Archetypes: `data-unit`, `app-unit`, `agent-unit`.
  **Provisioning of units is not built yet** — the schema records and validates them; the first
  archetype (`agent-unit`) lands in a later stage. Units deploy *inside the shared
  per-environment composition* (one state per env); independent per-unit state and divergent
  version pins are a documented future graduation, not built now (see ADR-0004).

## What is enforced today vs. recorded

- **Enforced now:** per-environment existence, layer `opt_in`, the `restricted → dedicated`
  guardrail (compute *and* composer), and unit validation (unknown `type` or missing `version`
  fails the plan).
- **Recorded but inert:** per-layer/per-unit `version` pins (Terraform can't take a dynamic
  module `?ref=`; deferred to the generator graduation in ADR-0004) and unit provisioning.

## `data_classification` drives compute isolation (ADR-0001 D14)

- `internal` / `confidential` → compute **may be `shared`** (namespace-isolated on the shared
  runtime plane — far cheaper).
- `restricted` → compute **must be `dedicated`** (regulated data may not share infrastructure).
  A `restricted` tenant with `isolation: shared` on compute or composer fails the plan.

## Examples

- [`abf.yaml`](abf.yaml) — `confidential`, shared compute, dev/acc/prod, dev runs a unit ahead of prod.
- [`helix.yaml`](helix.yaml) — `restricted`, dedicated compute + composer, dev + prod only.
