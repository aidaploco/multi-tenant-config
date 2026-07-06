# Registry integrity (same invariant the tenants root guards): this root keys namespaces and SA
# emails by FILENAME; the fleet's workspaces/matrices key by `slug`. They must agree.
resource "terraform_data" "registry_guard" {
  lifecycle {
    precondition {
      condition     = alltrue([for k, v in local.tenants_all : try(v.slug, "") == k])
      error_message = "Registry integrity: every tenants/<name>.yaml must set slug equal to its filename."
    }
  }
}

# One namespace per shared-compute tenant, with the full isolation contract (ADR-0013). Depends
# on BOTH the runtime cluster (provider access) and the tenant GSAs (created by the tenant root) —
# so this root applies after `runtime` and `tenants`.
module "tenant_namespace" {
  source   = "git::https://github.com/aidaploco/multi-tenant-platform.git//modules/tenant-namespace?ref=v0.8.0"
  for_each = local.namespaces

  namespace        = each.key
  owner_group      = each.value.owner_group
  service_accounts = each.value.service_accounts
  labels           = each.value.labels
}
