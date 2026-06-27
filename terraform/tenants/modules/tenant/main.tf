# tenant: per-tenant composition.
#
# Assembles one tenant's footprint from its YAML flags by calling the pinned
# platform-modules. This is invoked once per tenant by the for_each root -- there
# is no per-tenant directory or copy-pasted code, only this generic module plus
# data in the registry.
#
# Module refs are pinned to v0.1.0 (kept in sync with VERSIONS.md). The ref must
# be a string literal -- Terraform forbids a variable in a module source -- so a
# CI check greps these against VERSIONS.md.

locals {
  classification = var.tenant.data_classification

  # Effective compute isolation: explicit value if given, else defaulted from the
  # data classification (restricted -> dedicated, everything else -> shared).
  compute_isolation = try(
    var.tenant.layers.compute.isolation,
    local.classification == "restricted" ? "dedicated" : "shared"
  )

  project_id = "${var.slug}-${var.environment}"

  labels = {
    tenant              = var.slug
    environment         = var.environment
    data_classification = local.classification
  }

  storage_enabled = try(var.tenant.layers.storage, false)
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
    try(var.tenant.layers.bigquery, false) ? ["bigquery.googleapis.com"] : [],
    try(var.tenant.layers.ingestion, false) ? ["pubsub.googleapis.com"] : [],
  )
}

# Guardrail: regulated tenants may never share the compute plane (ADR-0001 D14).
# A failing precondition stops the plan before any resource is created.
resource "terraform_data" "guardrails" {
  lifecycle {
    precondition {
      condition     = !(local.classification == "restricted" && local.compute_isolation == "shared")
      error_message = "Tenant ${var.slug}: 'restricted' data_classification requires dedicated compute isolation, not shared."
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

# NOTE: ingestion (Pub/Sub), bigquery, compute (GKE) and composer layers plug in
# here with the same flag-driven pattern once those modules are built. For shared
# compute they create a namespace + Workload Identity SA in the runtime-<env>
# project; for dedicated they create resources in this tenant project.
