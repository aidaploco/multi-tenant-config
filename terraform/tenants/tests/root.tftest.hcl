# ADR-0014: the root deploys ONE tenant per workspace. Tests set var.tenant_slug because
# `terraform test` can't switch workspaces. Mocked provider; reads the real registry.

mock_provider "google" {}

variables {
  billing_account  = "0X0X0X-0X0X0X-0X0X0X"
  parent_folder_id = "folders/123456789"
  keys_project_id  = "company-keys"
  region           = "europe-west4"
}

run "deploys_the_workspace_tenant" {
  command = plan

  variables {
    environment = "dev"
    tenant_slug = "abf"
  }

  assert {
    condition     = length(output.selected_tenants) == 1 && contains(output.selected_tenants, "abf")
    error_message = "The root must deploy exactly the workspace's tenant."
  }
}

run "tenant_not_in_environment_is_rejected" {
  command = plan

  variables {
    environment = "acc"
    tenant_slug = "helix" # helix declares dev + prod only
  }

  expect_failures = [terraform_data.workspace_guard]
}

run "unknown_workspace_is_rejected" {
  command = plan

  variables {
    environment = "dev"
    tenant_slug = "does-not-exist"
  }

  expect_failures = [terraform_data.workspace_guard]
}
