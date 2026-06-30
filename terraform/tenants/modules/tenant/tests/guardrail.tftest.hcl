# Tests the composition guardrails and isolation defaulting (mocked provider).
# Schema v2 (ADR-0002): tenant config is per-environment; `environments` is a map.

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
      environments = {
        dev = {
          layers = { compute = { opt_in = true, isolation = "shared" } }
        }
      }
    }
  }

  expect_failures = [terraform_data.guardrails]
}

run "restricted_with_shared_composer_is_rejected" {
  command = plan

  variables {
    tenant = {
      display_name        = "Bad Composer Tenant"
      data_classification = "restricted"
      cmek_location       = "europe-west4"
      environments = {
        dev = {
          layers = { composer = { opt_in = true, isolation = "shared" } }
        }
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
      environments = {
        dev = {
          layers = { compute = { opt_in = true, isolation = "shared" } }
        }
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
      environments = {
        dev = {
          layers = { compute = { opt_in = true } }
        }
      }
    }
  }

  assert {
    condition     = output.compute_isolation == "dedicated"
    error_message = "Restricted tenant with no explicit isolation must default to dedicated."
  }
}

run "per_environment_override_wins_over_defaults" {
  command = plan
  variables {
    environment = "prod"
    tenant = {
      display_name        = "Override Tenant"
      data_classification = "confidential"
      cmek_location       = "europe-west4"
      defaults = {
        layers = { storage = { opt_in = true } }
      }
      environments = {
        dev  = {}
        prod = { layers = { storage = { opt_in = false } } }
      }
    }
  }

  # storage disabled in prod -> no buckets created for this environment.
  assert {
    condition     = length(output.bucket_names) == 0
    error_message = "prod override (storage opt_in=false) should win over the default opt_in=true."
  }
}

run "unknown_unit_type_is_rejected" {
  command = plan

  variables {
    tenant = {
      display_name        = "Bad Unit Tenant"
      data_classification = "confidential"
      cmek_location       = "europe-west4"
      environments = {
        dev = {
          units = { "x" = { type = "bogus-unit", version = "1.0.0", opt_in = true } }
        }
      }
    }
  }

  expect_failures = [terraform_data.guardrails]
}

run "valid_unit_is_accepted_and_surfaced" {
  command = plan

  variables {
    tenant = {
      display_name        = "Unit Tenant"
      data_classification = "confidential"
      cmek_location       = "europe-west4"
      environments = {
        dev = {
          units = { "search-a" = { type = "agent-unit", version = "1.4.0", opt_in = true } }
        }
      }
    }
  }

  assert {
    condition     = output.units["search-a"].type == "agent-unit"
    error_message = "A valid agent-unit should be accepted and surfaced in the units output."
  }
}

run "agent_unit_is_provisioned" {
  command = plan

  variables {
    tenant = {
      display_name        = "Agent Tenant"
      data_classification = "confidential"
      cmek_location       = "europe-west4"
      environments = {
        dev = {
          units = { "search-a" = { type = "agent-unit", version = "1.4.0", opt_in = true, overrides = { iam_roles = ["roles/storage.objectViewer"] } } }
        }
      }
    }
  }

  # The opted-in agent-unit must materialise an identity (the agent-identity module).
  assert {
    condition     = contains(keys(output.agent_identities), "search-a")
    error_message = "An opted-in agent-unit must be provisioned and surfaced in agent_identities."
  }
}
