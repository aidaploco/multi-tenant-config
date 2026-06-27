# tenants/ — the tenant registry

**One YAML file per tenant. This is the entire onboarding interface.** Adding a tenant is one
file + one PR; the Terraform root (`terraform/tenants/`) reads *every* file here and loops
with `for_each`. No per-tenant directories, no copy-paste, no code generation — that was the
single biggest failure mode in the platform this design learns from.

## Schema

| Field | Type | Meaning |
| ----- | ---- | ------- |
| `slug` | string | Short id; project prefix and label value. Lowercase, `[a-z0-9-]`. |
| `display_name` | string | Human-readable name. |
| `owner_group` | string | Google group that owns the tenant (project IAM). |
| `environments` | list | Subset of `[dev, acc, prod]` this tenant exists in. |
| `layers.storage` | bool | Provision GCS buckets. |
| `layers.ingestion` | bool | Provision Pub/Sub. |
| `layers.bigquery` | bool | Provision a BigQuery dataset. |
| `layers.compute.enabled` | bool | Provision compute (GKE) for the tenant. |
| `layers.compute.isolation` | enum | `shared` or `dedicated` (see below). |
| `layers.composer.enabled` | bool | Provision Cloud Composer orchestration. |
| `layers.composer.isolation` | enum | `shared` or `dedicated`. |
| `cmek_location` | string | KMS location for this tenant's CMEK keys. |
| `budget_usd` | number | Drives billing **alerts** (not a hard cap). |
| `data_classification` | enum | `internal` \| `confidential` \| `restricted`. |

## `data_classification` drives compute isolation (ADR-0001 D14)

- `internal` / `confidential` → compute **may be `shared`** (namespace-isolated on the shared
  runtime plane — far cheaper).
- `restricted` → compute **must be `dedicated`** (regulated data may not share infrastructure).

The Terraform root enforces this: a `restricted` tenant with `isolation: shared` fails the plan.

## Examples

- [`abf.yaml`](abf.yaml) — `confidential`, shared compute, all three environments.
- [`helix.yaml`](helix.yaml) — `restricted`, dedicated compute, dev + prod only.
