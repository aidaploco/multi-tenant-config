# Tests the eligibility filtering: shared-compute tenants get a namespace; dedicated/restricted
# ones don't. Mocked providers — no cloud, no cluster. Reads the real tenants/ registry.

mock_provider "google" {}
mock_provider "kubernetes" {}

run "dev_shared_tenants_get_namespaces" {
  command = plan

  variables {
    environment = "dev"
  }

  assert {
    condition     = contains(output.tenant_namespaces, "abf")
    error_message = "abf (confidential, shared compute) must get a shared namespace."
  }

  assert {
    condition     = !contains(output.tenant_namespaces, "helix")
    error_message = "helix (restricted, dedicated) must NOT get a shared namespace."
  }
}

# kind mode (ADR-0018): the GCP data sources are count-gated off, and the SAME tenants get the
# SAME namespaces — the isolation contract must not vary by cluster_mode.
run "kind_mode_plans_without_gcp_and_matches" {
  command = plan

  variables {
    environment  = "dev"
    cluster_mode = "kind"
  }

  assert {
    condition     = contains(output.tenant_namespaces, "abf") && !contains(output.tenant_namespaces, "helix")
    error_message = "kind mode must produce the identical namespace set (abf in, helix out)."
  }

  assert {
    condition     = length(data.google_project.runtime) == 0 && length(data.google_client_config.default) == 0
    error_message = "kind mode must not instantiate any GCP data source (plans need zero cloud credentials)."
  }
}
