# The data-driven core of the platform.
#
# ADR-0014: per-tenant state via Terraform workspaces. This root deploys the SINGLE tenant named by
# the workspace (var.tenant_slug overrides it in tests). The registry is still the one interface --
# we read all of it -- but we SELECT one tenant, not `for_each` over the whole fleet. Each workspace
# = its own state file + lock (per-tenant blast radius). No generator; adding a tenant is still one
# YAML + one PR (CI runs `terraform workspace new/select <slug>`).

locals {
  tenant_files = fileset("${path.module}/../../tenants", "*.yaml")

  tenants_all = {
    for f in local.tenant_files :
    trimsuffix(f, ".yaml") => yamldecode(file("${path.module}/../../tenants/${f}"))
  }

  # The tenant to deploy = the workspace name (or the test override).
  slug   = coalesce(var.tenant_slug, terraform.workspace)
  tenant = lookup(local.tenants_all, local.slug, null)

  # Valid only if that tenant exists AND declares this environment.
  valid    = local.tenant != null && contains(keys(try(local.tenant.environments, {})), var.environment)
  selected = local.valid ? { (local.slug) = local.tenant } : {}
}
