# Unit tests for the tenant composition. Mocked google provider — verifies WIRING (the ADR-0025
# alert-termination pieces: owner channel from the registry's owner_group, budget_usd becoming
# a real budget with the per-environment override honored). Live behavior (emails actually
# delivered, budgets actually firing) is register-tracked (VERIFICATION.md), not testable here.

mock_provider "google" {}

variables {
  slug             = "abf"
  environment      = "dev"
  billing_account  = "0X0X0X-0X0X0X-0X0X0X"
  parent_folder_id = "folders/123456789"
  keys_project_id  = "company-keys"
  region           = "europe-west4"

  tenant = {
    slug                = "abf"
    display_name        = "ABF Analytics"
    owner_group         = "abf-data-engineers@company.com"
    data_classification = "confidential"
    cmek_location       = "europe-west4"
    defaults = {
      budget_usd    = 5000
      layers        = { storage = { opt_in = true } }
      units         = {}
      feature_flags = {}
    }
    environments = {
      dev  = {}
      prod = { budget_usd = 8000 }
    }
  }
}

run "owner_channel_terminates_at_the_registry_group" {
  command = plan

  assert {
    condition     = google_monitoring_notification_channel.owner.labels["email_address"] == "abf-data-engineers@company.com"
    error_message = "The notification channel must address the registry's owner_group (ADR-0025 D25-2) — no separate routing table."
  }
}

run "budget_usd_becomes_a_real_budget" {
  command = plan

  assert {
    condition     = one(google_billing_budget.tenant).amount[0].specified_amount[0].units == "5000"
    error_message = "defaults.budget_usd must drive the billing budget (ADR-0025 D25-3)."
  }

  assert {
    condition     = length(one(google_billing_budget.tenant).threshold_rules) == 3
    error_message = "Budget must alert at 50/90/100%."
  }

  assert {
    condition     = one(google_billing_budget.tenant).all_updates_rule[0].disable_default_iam_recipients == true
    error_message = "Budget alerts go to the owner channel, not whoever holds IAM (ADR-0025 D25-3)."
  }
}

run "environment_budget_override_wins" {
  command = plan

  variables {
    environment = "prod"
  }

  assert {
    condition     = one(google_billing_budget.tenant).amount[0].specified_amount[0].units == "8000"
    error_message = "The environment's budget_usd override must beat the tenant default (ADR-0002 shallow-merge)."
  }
}
