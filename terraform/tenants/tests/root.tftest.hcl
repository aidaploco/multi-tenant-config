# Tests the data-driven core: the right tenants are selected per environment.
# Mocked provider -> no cloud, no cost. Reads the real tenants/ registry.

mock_provider "google" {}

variables {
  billing_account  = "0X0X0X-0X0X0X-0X0X0X"
  parent_folder_id = "folders/123456789"
  keys_project_id  = "company-keys"
  region           = "europe-west4"
}

run "dev_includes_all_tenants" {
  command = plan

  variables {
    environment = "dev"
  }

  assert {
    condition     = contains(output.selected_tenants, "abf") && contains(output.selected_tenants, "helix")
    error_message = "Both abf and helix declare dev; both should be selected."
  }
}

run "staging_excludes_tenant_not_in_staging" {
  command = plan

  variables {
    environment = "staging"
  }

  assert {
    condition     = contains(output.selected_tenants, "abf")
    error_message = "abf declares staging and should be selected."
  }

  assert {
    condition     = !contains(output.selected_tenants, "helix")
    error_message = "helix does not declare staging and must be excluded."
  }
}
