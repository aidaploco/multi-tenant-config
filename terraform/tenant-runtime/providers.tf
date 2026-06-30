# Reaches the PRIVATE runtime cluster's API through Fleet Connect Gateway (ADR-0013 D13-2) — no
# direct network path, no authorized-network holes. Auth is the applier SA's short-lived token
# (keyless, D5). The cluster is Fleet-registered by the config-sync module.
#
# NOTE: the Connect Gateway host format is the single most apply-sensitive line in the platform —
# confirm it against a live membership on first real apply.

data "google_client_config" "default" {}

data "google_project" "runtime" {
  project_id = "runtime-${var.environment}"
}

provider "google" {
  region = var.region
}

provider "kubernetes" {
  host  = "https://connectgateway.googleapis.com/v1/projects/${data.google_project.runtime.number}/locations/global/gkeMemberships/runtime-cluster-membership"
  token = data.google_client_config.default.access_token
}
