# tenant: per-tenant composition.
#
# Assembles one tenant's footprint from its YAML flags by calling the pinned
# multi-tenant-platform. ADR-0014: this root deploys ONE tenant per Terraform workspace
# (terraform.workspace selects which tenant), not a for_each loop over all of
# them -- per-(tenant,env) state, a per-tenant CI matrix. Still no per-tenant
# directory or copy-pasted code: one generic module, data in the registry.
#
# Schema v2 (ADR-0002, amended by ADR-0011): config is per-environment. We resolve
# the effective config for var.environment by shallow-merging this environment's
# overrides over the tenant defaults. Layers are objects {opt_in, isolation?} --
# ADR-0011 removed the per-layer `version` field; units are axis-2 workloads
# (validated here, provisioned in a later stage).
#
# Module refs are pinned per VERSIONS.md (currently a mix of v0.1.0 and later --
# agent-identity is v0.2.0, for example). The ref must be a string literal --
# Terraform forbids a variable in a module source -- so a CI check greps these
# against VERSIONS.md. ADR-0011: platform-module versions are fleet-wide, full
# stop -- there is no per-tenant/per-layer version pin to enforce, recorded or
# otherwise (ADR-0002 D2-6 is superseded).

locals {
  classification = var.tenant.data_classification

  # Effective config for this environment = defaults <- this env's overrides (shallow).
  defaults   = try(var.tenant.defaults, {})
  env_config = try(var.tenant.environments[var.environment], {})

  layers = merge(try(local.defaults.layers, {}), try(local.env_config.layers, {}))
  units  = merge(try(local.defaults.units, {}), try(local.env_config.units, {}))
  # feature_flags is a schema field (defaults/env) consumed once an archetype needs it; not
  # pre-merged here until then (an unused local is dead code — caught by tflint in CI).

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

  # Platform-module versions are fleet-wide (VERSIONS.md), NOT per-tenant (ADR-0011). The
  # registry carries no layer version. A unit's `version` is its app release (optional).

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

# Alerts terminate somewhere (ADR-0025 D25-2): one email channel per tenant environment,
# addressed to the registry's owner_group — the field ADR-0002 has carried since day one. No
# routing table, no label→receiver funnel: alerts live in the tenant's own project, so the
# resource boundary IS the routing. Every observability invocation and the budget below feed
# this channel; the OPA gate (policies v0.14.0) denies any alert policy wired to nothing.
resource "google_monitoring_notification_channel" "owner" {
  project      = module.project.project_id
  display_name = "${var.tenant.display_name} owners (${var.environment})"
  type         = "email"

  labels = {
    email_address = var.tenant.owner_group
  }

  user_labels = merge(local.labels, { severity = "all" }) # severity split = future refinement
}

module "bucket_observability" {
  source   = "git::https://github.com/aidaploco/multi-tenant-platform.git//modules/observability?ref=v0.1.0"
  for_each = module.buckets

  project_id            = module.project.project_id
  display_name          = each.value.name
  metric_filter         = "resource.type=\"gcs_bucket\" AND resource.label.bucket_name=\"${each.value.name}\" AND metric.type=\"storage.googleapis.com/network/sent_bytes_count\""
  notification_channels = [google_monitoring_notification_channel.owner.id]
  labels                = local.labels
}

# budget_usd stops being plan-decoration (ADR-0025 D25-3): a real budget on the billing
# account, filtered to this tenant environment's project, thresholds to the owner channel.
# disable_default_iam_recipients: the owner group is the owner — not whoever holds IAM.
# Actual delivery + the billingbudgets quota-project requirement are activation-only (row 16).
locals {
  budget_usd = try(local.env_config.budget_usd, try(local.defaults.budget_usd, null))
}

resource "google_billing_budget" "tenant" {
  count = local.budget_usd != null ? 1 : 0

  billing_account = var.billing_account
  display_name    = "${local.project_id} budget"

  budget_filter {
    projects = ["projects/${module.project.project_number}"]
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(local.budget_usd)
    }
  }

  threshold_rules {
    threshold_percent = 0.5
  }
  threshold_rules {
    threshold_percent = 0.9
  }
  threshold_rules {
    threshold_percent = 1.0
  }

  all_updates_rule {
    monitoring_notification_channels = [google_monitoring_notification_channel.owner.id]
    disable_default_iam_recipients   = true
  }
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
