# The loop. One generic module invocation, every tenant in this environment.
module "tenant" {
  source   = "./modules/tenant"
  for_each = local.tenants_for_env

  slug             = each.key
  tenant           = each.value
  environment      = var.environment
  billing_account  = var.billing_account
  parent_folder_id = var.parent_folder_id
  keys_project_id  = var.keys_project_id
  region           = var.region
}
