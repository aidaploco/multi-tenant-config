# The shared runtime plane for one environment (ADR-0001 D13, ADR-0008). Platform-owned, NOT
# per-tenant: a project under the runtime/ folder holding the private VPC the shared GKE Autopilot
# and Cloud Composer will run on (milestone parts 3-4). One per environment.

module "project" {
  source = "git::https://github.com/aidaploco/multi-tenant-platform.git//modules/gcp-project?ref=v0.1.0"

  project_id      = local.project_id
  display_name    = "Runtime ${var.environment}"
  folder_id       = var.runtime_folder_id
  billing_account = var.billing_account

  activate_apis = [
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
    "iam.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "compute.googleapis.com",
    "container.googleapis.com",
  ]

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

module "cluster" {
  source = "git::https://github.com/aidaploco/multi-tenant-platform.git//modules/gke-autopilot?ref=v0.5.0"

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

  deletion_protection = var.environment == "prod"
  labels              = local.labels
}

# NOTE: Cloud Composer (part 3b) attaches to module.vpc next. Config Sync + the gitops/ manifests
# (part 4) then reconcile per-tenant namespaces with default-deny NetworkPolicy onto module.cluster.
# Until part 4, do not run two tenants' workloads here.
