# ADR-0014: one tenant per Terraform workspace. The workspace names the tenant; each workspace has
# its own state + lock, so one tenant's bad plan/apply can never wedge another's. No fleet-wide
# `for_each`, no generator.

# The workspace must name a real tenant that exists in this environment.
resource "terraform_data" "workspace_guard" {
  lifecycle {
    precondition {
      condition     = local.valid
      error_message = "Workspace '${local.slug}' is not a tenant present in environment '${var.environment}'. Run: terraform workspace select <slug>."
    }
  }
}

# One instance, keyed by the workspace. local.selected is {} for an invalid workspace, so the module
# never evaluates against a null tenant -- the guard above fails the plan loudly instead.
module "tenant" {
  source   = "./modules/tenant"
  for_each = local.selected

  slug             = each.key
  tenant           = each.value
  environment      = var.environment
  billing_account  = var.billing_account
  parent_folder_id = var.parent_folder_id
  keys_project_id  = var.keys_project_id
  region           = var.region
}
