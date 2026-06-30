# Tests the runtime-plane root: one runtime-<env> project + its private VPC. Mocked provider.

mock_provider "google" {}

variables {
  billing_account   = "0X0X0X-0X0X0X-0X0X0X"
  runtime_folder_id = "folders/123456789"
}

run "dev_runtime_project" {
  command = plan

  variables {
    environment = "dev"
  }

  assert {
    condition     = output.runtime_project_id == "runtime-dev"
    error_message = "Runtime project must be named runtime-<env>."
  }

  assert {
    condition     = output.pods_range_name == "pods" && output.services_range_name == "services"
    error_message = "VPC-native secondary ranges must surface for the GKE cluster."
  }
}

run "prod_runtime_project" {
  command = plan

  variables {
    environment = "prod"
  }

  assert {
    condition     = output.runtime_project_id == "runtime-prod"
    error_message = "Runtime project must be named runtime-<env>."
  }
}
