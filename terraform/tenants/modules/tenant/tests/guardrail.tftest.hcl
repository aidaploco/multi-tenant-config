# Tests the composition guardrails and isolation defaulting (mocked provider).

mock_provider "google" {}

variables {
  slug             = "test"
  environment      = "dev"
  billing_account  = "0X0X0X-0X0X0X-0X0X0X"
  parent_folder_id = "folders/123456789"
  keys_project_id  = "company-keys"
  region           = "europe-west4"
}

run "restricted_with_shared_compute_is_rejected" {
  command = plan

  variables {
    tenant = {
      display_name        = "Bad Tenant"
      data_classification = "restricted"
      cmek_location       = "europe-west4"
      environments        = ["dev"]
      layers = {
        storage = true
        compute = { enabled = true, isolation = "shared" }
      }
    }
  }

  expect_failures = [terraform_data.guardrails]
}

run "confidential_shared_is_allowed" {
  command = plan

  variables {
    tenant = {
      display_name        = "Good Tenant"
      data_classification = "confidential"
      cmek_location       = "europe-west4"
      environments        = ["dev"]
      layers = {
        storage = true
        compute = { enabled = true, isolation = "shared" }
      }
    }
  }

  assert {
    condition     = output.compute_isolation == "shared"
    error_message = "Confidential tenant should keep shared isolation."
  }
}

run "restricted_defaults_to_dedicated_when_unspecified" {
  command = plan

  variables {
    tenant = {
      display_name        = "Reg Tenant"
      data_classification = "restricted"
      cmek_location       = "europe-west4"
      environments        = ["dev"]
      layers = {
        storage = true
        compute = { enabled = true }
      }
    }
  }

  assert {
    condition     = output.compute_isolation == "dedicated"
    error_message = "Restricted tenant with no explicit isolation must default to dedicated."
  }
}
