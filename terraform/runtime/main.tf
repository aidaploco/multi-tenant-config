# The shared runtime plane for one environment (ADR-0001 D13, ADR-0008). Platform-owned, NOT
# per-tenant: a project under the runtime/ folder holding the private VPC the shared GKE Autopilot
# and Cloud Composer will run on (milestone parts 3-4). One per environment.

module "project" {
  source = "git::https://github.com/aidaploco/multi-tenant-platform.git//modules/gcp-project?ref=v0.1.0"

  project_id      = local.project_id
  display_name    = "Runtime ${var.environment}"
  folder_id       = var.runtime_folder_id
  billing_account = var.billing_account

  activate_apis = concat(
    [
      "cloudresourcemanager.googleapis.com",
      "serviceusage.googleapis.com",
      "iam.googleapis.com",
      "logging.googleapis.com",
      "monitoring.googleapis.com",
      "compute.googleapis.com",
      "container.googleapis.com",
      "gkehub.googleapis.com",
      "anthosconfigmanagement.googleapis.com",
      "secretmanager.googleapis.com",
      "cloudkms.googleapis.com", # substrate CMEK keys (ADR-0025 D25-1)
    ],
    var.composer_enabled ? ["composer.googleapis.com"] : [],
  )

  deletion_policy = var.environment == "prod" ? "PREVENT" : "DELETE"
  labels          = local.labels
}

module "vpc" {
  source = "git::https://github.com/aidaploco/multi-tenant-platform.git//modules/shared-vpc?ref=v0.4.0"

  project_id    = module.project.project_id
  network_name  = "runtime-vpc"
  region        = var.region
  subnet_cidr   = local.net.subnet
  pods_cidr     = local.net.pods
  services_cidr = local.net.services
}

# Substrate CMEK keys (ADR-0025 D25-1): PLATFORM keys for the platform plane. Deliberate,
# stated deviation from the tenant pattern (dedicated keys project): here both the keys and
# the encrypted substrate are platform-owned, so separation-of-duties buys little — revisit at
# activation if the org lands a platform keys project (VERIFICATION.md row 16). Two keys, not
# one: independent rotation and blast radius per surface (etcd Secrets vs node disks).
module "platform_keys" {
  source = "git::https://github.com/aidaploco/multi-tenant-platform.git//modules/kms-tenant?ref=v0.1.0"

  project_id   = module.project.project_id
  keyring_name = "${local.project_id}-platform-keyring"
  location     = var.region
  keys         = ["gke-secrets", "gke-disks"]
  labels       = local.labels
}

# The service agents that do the encrypting need use of their key (grant-vs-first-cluster
# ordering is register-tracked, row 16 — same seam as the GCS agent grant, row 8).
resource "google_kms_crypto_key_iam_member" "gke_secrets_agent" {
  crypto_key_id = module.platform_keys.key_ids["gke-secrets"]
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:service-${module.project.project_number}@container-engine-robot.iam.gserviceaccount.com"
}

resource "google_kms_crypto_key_iam_member" "gke_disks_agent" {
  crypto_key_id = module.platform_keys.key_ids["gke-disks"]
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:service-${module.project.project_number}@compute-system.iam.gserviceaccount.com"
}

module "cluster" {
  source = "git::https://github.com/aidaploco/multi-tenant-platform.git//modules/gke-autopilot?ref=v0.14.0"

  project_id          = module.project.project_id
  name                = "runtime-cluster"
  region              = var.region
  network             = module.vpc.network_id
  subnetwork          = module.vpc.subnetwork_id
  pods_range_name     = module.vpc.pods_range_name
  services_range_name = module.vpc.services_range_name
  master_ipv4_cidr    = local.net.master

  # Empty = no external control-plane access (admin via IAP). Add an admin CIDR here if needed.
  master_authorized_networks = []

  # Substrate CMEK (ADR-0025 D25-1) — required by the module, fail-closed.
  database_encryption_key = module.platform_keys.key_ids["gke-secrets"]
  boot_disk_kms_key       = module.platform_keys.key_ids["gke-disks"]

  deletion_protection = var.environment == "prod"
  labels              = local.labels

  depends_on = [
    google_kms_crypto_key_iam_member.gke_secrets_agent,
    google_kms_crypto_key_iam_member.gke_disks_agent,
  ]
}

# PARKED (ADR-0016 D16-1): Temporal owns agentic orchestration; Composer is kept for the day a
# scheduled batch data-pipeline tenant arrives, behind this flag — default OFF everywhere. Do
# not extend it and do not couple anything new to it. Unparking requires the checklist in
# docs/PLAN.md ("Parked / scrapped") — the ADR-0015 Airflow-isolation set — before it ever
# serves two tenants.
module "composer" {
  source = "git::https://github.com/aidaploco/multi-tenant-platform.git//modules/cloud-composer?ref=v0.6.0"
  count  = var.composer_enabled ? 1 : 0

  project_id            = module.project.project_id
  name                  = "runtime-composer"
  region                = var.region
  network               = module.vpc.network_id
  subnetwork            = module.vpc.subnetwork_id
  master_ipv4_cidr      = local.net.composer_master
  composer_network_cidr = local.net.composer_network
  web_server_cidr       = local.net.composer_web
  labels                = local.labels
}

module "config_sync" {
  source = "git::https://github.com/aidaploco/multi-tenant-platform.git//modules/config-sync?ref=v0.9.0"

  project_id   = module.project.project_id
  region       = var.region
  cluster_name = module.cluster.name
  cluster_id   = module.cluster.id
  sync_repo    = "https://github.com/aidaploco/multi-tenant-config"
  secret_type  = "token" # OCI + Workload Identity is the keyless hardening (ADR-0012 D12-4)
  labels       = local.labels
}

# NOTE: Config Sync now reconciles the gitops/ cluster baseline. Per-tenant namespaces (with
# default-deny NetworkPolicy / quota / RBAC) are created by the TENANT composition, data-driven —
# that wiring (which couples to cluster access) is the remaining follow-on before two tenants
# share the cluster (ADR-0012).
