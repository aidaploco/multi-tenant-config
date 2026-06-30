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
