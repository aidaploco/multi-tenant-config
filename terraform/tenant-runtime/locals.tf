# Data-driven, like the tenant root: read the registry, and for every tenant that opts into SHARED
# compute in this environment, build its namespace inputs. Dedicated/restricted tenants (D14) run
# their own compute and get no shared namespace.

locals {
  tenant_files = fileset("${path.module}/../../tenants", "*.yaml")
  tenants_all = {
    for f in local.tenant_files :
    trimsuffix(f, ".yaml") => yamldecode(file("${path.module}/../../tenants/${f}"))
  }

  # Effective per-tenant config for this environment (defaults <- env override, same shape as the
  # tenant module).
  eff = {
    for k, v in local.tenants_all : k => {
      in_env         = contains(keys(v.environments), var.environment)
      classification = v.data_classification
      owner_group    = v.owner_group
      layers         = merge(try(v.defaults.layers, {}), try(v.environments[var.environment].layers, {}))
      units          = merge(try(v.defaults.units, {}), try(v.environments[var.environment].units, {}))
    }
  }

  # Eligible = exists in env, compute opted-in, and NOT dedicated.
  shared_tenants = {
    for k, e in local.eff : k => e
    if e.in_env
    && try(e.layers.compute.opt_in, false)
    && try(e.layers.compute.isolation, e.classification == "restricted" ? "dedicated" : "shared") != "dedicated"
  }

  # Per-tenant namespace inputs. Each agent-unit gets a KSA mapped to its GCP SA in the tenant
  # project (`<slug>-<unit>@<slug>-<env>.iam.gserviceaccount.com`).
  namespaces = {
    for k, e in local.shared_tenants : k => {
      owner_group = e.owner_group
      labels      = { tenant = k, environment = var.environment, data_classification = e.classification }
      service_accounts = {
        for name, u in e.units : name => "${k}-${name}@${k}-${var.environment}.iam.gserviceaccount.com"
        if try(u.type, "") == "agent-unit" && try(u.opt_in, true)
      }
    }
  }
}
