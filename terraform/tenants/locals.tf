# The data-driven core of the platform.
#
# Read EVERY tenant YAML, decode it, and keep the ones that exist in the
# environment being deployed. main.tf then for_each-es over this map. Adding a
# tenant is a new file here; no code changes, ever.

locals {
  tenant_files = fileset("${path.module}/../../tenants", "*.yaml")

  tenants_all = {
    for f in local.tenant_files :
    trimsuffix(f, ".yaml") => yamldecode(file("${path.module}/../../tenants/${f}"))
  }

  # Filter to the tenants present in the target environment. One apply (and one
  # state file) per environment.
  tenants_for_env = {
    for k, v in local.tenants_all : k => v
    if contains(v.environments, var.environment)
  }
}
