# Two cluster modes (ADR-0018), one root — the SAME namespace/policy resources apply to both:
#
# - connectgateway: the PRIVATE runtime cluster's API through Fleet Connect Gateway (ADR-0013
#   D13-2) — no direct network path, no authorized-network holes. Auth is the applier SA's
#   short-lived token (keyless, D5). The cluster is Fleet-registered by the config-sync module.
#   NOTE: the Connect Gateway host format is the single most apply-sensitive line in the
#   platform — confirm it against a live membership on first real apply (VERIFICATION #4).
#
# - kind: the local mock-first plane. Everything GCP is count-gated OFF so this root plans and
#   applies with ZERO cloud credentials (the google_project data source used to break even
#   `terraform plan` without them). The isolation contract itself is identical — which is the
#   point: what kind verifies live, Connect Gateway only re-verifies transport for.

locals {
  kind_mode = var.cluster_mode == "kind"
}

data "google_client_config" "default" {
  count = local.kind_mode ? 0 : 1
}

data "google_project" "runtime" {
  count      = local.kind_mode ? 0 : 1
  project_id = "runtime-${var.environment}"
}

provider "google" {
  region = var.region
  # No resource in this root uses the google provider in kind mode (both data sources above are
  # count=0) — but the provider still calls Configure() and, finding neither `credentials` nor
  # `access_token` set, eagerly attempts Application Default Credentials and fails even though
  # nothing would ever use them. A placeholder token skips that lookup; it is never sent anywhere.
  # (Referencing google_client_config here in the non-kind branch would cycle: that data source
  # is itself a resource OF this provider. Leave it null there — real mode keeps its original
  # ADC-via-environment behavior, e.g. the CI applier's WIF-issued credentials.)
  access_token = local.kind_mode ? "unused-in-kind-mode" : null
}

provider "kubernetes" {
  # Connect Gateway path (unused refs are try-guarded: with count=0 they must not error).
  host  = local.kind_mode ? null : "https://connectgateway.googleapis.com/v1/projects/${try(data.google_project.runtime[0].number, "")}/locations/global/gkeMemberships/runtime-cluster-membership"
  token = local.kind_mode ? null : try(data.google_client_config.default[0].access_token, null)

  # kind path: the local cluster is named runtime-<env> (scripts/kind/up.sh), so the context
  # kind-runtime-<env> must exist in the default kubeconfig.
  config_path    = local.kind_mode ? "~/.kube/config" : null
  config_context = local.kind_mode ? "kind-runtime-${var.environment}" : null
}
