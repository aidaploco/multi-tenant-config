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

  assert {
    condition     = output.workload_pool == "runtime-dev.svc.id.goog"
    error_message = "The cluster's Workload Identity pool must be runtime-<env>.svc.id.goog."
  }

  assert {
    condition     = output.composer_name == "runtime-composer"
    error_message = "The shared Composer environment must be wired into the runtime plane."
  }

  assert {
    condition     = output.config_sync_membership == "runtime-cluster-membership"
    error_message = "Config Sync must register the runtime cluster into the fleet."
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
