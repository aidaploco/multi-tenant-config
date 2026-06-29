# tenant: per-tenant composition.
#
# Assembles one tenant's footprint from its YAML flags by calling the pinned
# platform-modules. This is invoked once per tenant by the for_each root -- there
# is no per-tenant directory or copy-pasted code, only this generic module plus
# data in the registry.
#
# Schema v2 (ADR-0002): config is per-environment. We resolve the effective config
# for var.environment by shallow-merging this environment's overrides over the
# tenant defaults. Layers are objects {opt_in, version, isolation?}; units are
# axis-2 workloads (validated here, provisioned in a later stage).
#
# Module refs are pinned to v0.1.0 (kept in sync with VERSIONS.md). The ref must
# be a string literal -- Terraform forbids a variable in a module source -- so a
# CI check greps these against VERSIONS.md. (This is exactly why per-layer version
# pins are RECORDED but not yet enforced: see ADR-0002 D2-6.)

locals {
  classification = var.tenant.data_classification

  # Effective config for this environment = defaults <- this env's overrides (shallow).
  defaults   = try(var.tenant.defaults, {})
  env_config = try(var.tenant.environments[var.environment], {})

  layers        = merge(try(local.defaults.layers, {}), try(local.env_config.layers, {}))
  units         = merge(try(local.defaults.units, {}), try(local.env_config.units, {}))
  feature_flags = merge(try(local.defaults.feature_flags, {}), try(local.env_config.feature_flags, {}))

  # Layer opt-in (axis 1).
  storage_enabled   = try(local.layers.storage.opt_in, false)
  ingestion_enabled = try(local.layers.ingestion.opt_in, false)
  bigquery_enabled  = try(local.layers.bigquery.opt_in, false)
  compute_enabled   = try(local.layers.compute.opt_in, false)
  composer_enabled  = try(local.layers.composer.opt_in, false)

  # Effective isolation: explicit value if given, else defaulted from the data
  # classification (restricted -> dedicated, everything else -> shared).
  default_isolation  = local.classification == "restricted" ? "dedicated" : "shared"
  compute_isolation  = try(local.layers.compute.isolation, local.default_isolation)
  composer_isolation = try(local.layers.composer.isolation, local.default_isolation)

  # Recorded-but-inert: per-layer version pins, surfaced for visibility. NOT yet wired
  # to module source refs (needs Terragrunt Stacks -- ADR-0002 D2-6).
  layer_versions = { for name, cfg in local.layers : name => try(cfg.version, null) }

  # Axis-2 archetypes recognised by the platform. Unit provisioning is not built yet;
  # the schema is validated now so bad data fails fast.
  allowed_unit_types = ["data-unit", "app-unit", "agent-unit"]

  project_id = "${var.slug}-${var.environment}"

  labels = {
    tenant              = var.slug
    environment         = var.environment
    data_classification = local.classification
  }

  bucket_suffixes = local.storage_enabled ? ["landing", "processing", "archive"] : []

  # Enable only the APIs the tenant's layers require (minimal attack surface).
  base_apis = [
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
    "iam.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "cloudkms.googleapis.com",
  ]
  activate_apis = concat(
    local.base_apis,
    local.storage_enabled ? ["storage.googleapis.com"] : [],
    local.bigquery_enabled ? ["bigquery.googleapis.com"] : [],
    local.ingestion_enabled ? ["pubsub.googleapis.com"] : [],
  )
}

# Guardrails. A failing precondition stops the plan before any resource is created.
resource "terraform_data" "guardrails" {
  lifecycle {
    # Regulated tenants may never share the compute plane (ADR-0001 D14).
    precondition {
      condition     = !(local.classification == "restricted" && local.compute_enabled && local.compute_isolation == "shared")
      error_message = "Tenant ${var.slug}: 'restricted' data_classification requires dedicated compute isolation, not shared."
    }

    # ...nor the composer/orchestration plane.
    precondition {
      condition     = !(local.classification == "restricted" && local.composer_enabled && local.composer_isolation == "shared")
      error_message = "Tenant ${var.slug}: 'restricted' data_classification requires dedicated composer isolation, not shared."
    }

    # Every declared scale unit must use a known archetype (ADR-0002 D2-4).
    precondition {
      condition     = alltrue([for name, u in local.units : contains(local.allowed_unit_types, try(u.type, ""))])
      error_message = "Tenant ${var.slug}: every unit must declare a known type (one of ${join(", ", local.allowed_unit_types)})."
    }

    # ...and pin a version (ADR-0002 D2-3: unit versions are first-class).
    precondition {
      condition     = alltrue([for name, u in local.units : try(u.version, null) != null])
      error_message = "Tenant ${var.slug}: every unit must pin a version."
    }
  }
}

module "project" {
  source = "git::https://github.com/aidaploco/multi-tenant-platform.git//modules/gcp-project?ref=v0.1.0"

  project_id      = local.project_id
  display_name    = "${var.tenant.display_name} ${var.environment}"
  folder_id       = var.parent_folder_id
  billing_account = var.billing_account
  activate_apis   = local.activate_apis
  deletion_policy = var.environment == "prod" ? "PREVENT" : "DELETE"
  labels          = local.labels
}

module "keys" {
  source = "git::https://github.com/aidaploco/multi-tenant-platform.git//modules/kms-tenant?ref=v0.1.0"

  project_id       = var.keys_project_id
  keyring_name     = "${var.slug}-${var.environment}-keyring"
  location         = try(var.tenant.cmek_location, var.region)
  protection_level = local.classification == "restricted" ? "HSM" : "SOFTWARE"
  labels           = local.labels
}

# Storage layer (flag-driven). Each bucket is CMEK-encrypted with the tenant's
# gcs key and gets platform-shipped observability.
module "buckets" {
  source   = "git::https://github.com/aidaploco/multi-tenant-platform.git//modules/gcs?ref=v0.1.0"
  for_each = toset(local.bucket_suffixes)

  project_id  = module.project.project_id
  name        = "${local.project_id}-${each.value}"
  location    = var.region
  cmek_key_id = module.keys.key_ids["gcs"]
  labels      = local.labels
}

module "bucket_observability" {
  source   = "git::https://github.com/aidaploco/multi-tenant-platform.git//modules/observability?ref=v0.1.0"
  for_each = module.buckets

  project_id    = module.project.project_id
  display_name  = each.value.name
  metric_filter = "resource.type=\"gcs_bucket\" AND resource.label.bucket_name=\"${each.value.name}\" AND metric.type=\"storage.googleapis.com/network/sent_bytes_count\""
  labels        = local.labels
}

# --- Axis-2 scale units ---
# Per ADR-0004, units deploy INSIDE this per-environment composition (shared state), not as
# independent Terragrunt roots. First archetype wired in: agent-unit (a runtime identity).
locals {
  agent_units = {
    for name, u in local.units : name => u
    if try(u.type, "") == "agent-unit" && try(u.opt_in, true)
  }

  # Shared runtime project for this environment (ADR-0001 D13). Created in a later stage; the
  # Workload Identity binding below is valid IAM ahead of the cluster existing.
  runtime_project_id = "runtime-${var.environment}"
}

module "agent_identity" {
  source   = "git::https://github.com/aidaploco/multi-tenant-platform.git//modules/agent-identity?ref=v0.2.0"
  for_each = local.agent_units

  project_id   = module.project.project_id
  account_id   = "${var.slug}-${each.key}"
  display_name = "${var.tenant.display_name} ${each.key}"
  iam_roles    = try(each.value.overrides.iam_roles, [])

  workload_identity = {
    runtime_project_id = local.runtime_project_id
    namespace          = var.slug
    ksa_name           = each.key
  }
}

# NOTE: ingestion (Pub/Sub), bigquery, compute (GKE) and composer layers plug in here with the
# same flag-driven pattern once those modules are built. The data-unit and app-unit archetypes
# follow agent-unit's shape above. None of these get independent per-unit state — that is the
# documented generator-graduation, not built now (ADR-0004).
