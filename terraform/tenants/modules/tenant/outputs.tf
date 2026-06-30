output "project_id" {
  description = "The tenant's project ID for this environment."
  value       = module.project.project_id
}

output "bucket_names" {
  description = "Map of bucket suffix -> full bucket name (empty if storage layer disabled)."
  value       = { for k, m in module.buckets : k => m.name }
}

output "keyring_id" {
  description = "The tenant's KMS keyring ID."
  value       = module.keys.keyring_id
}

output "compute_isolation" {
  description = "Effective compute isolation (shared|dedicated) after applying the classification default."
  value       = local.compute_isolation
}

output "units" {
  description = "Axis-2 scale units declared for this environment (the full validated set)."
  value = {
    for name, u in local.units : name => {
      type    = try(u.type, null)
      version = try(u.version, null)
      opt_in  = try(u.opt_in, true)
    }
  }
}

output "agent_identities" {
  description = "Provisioned agent-unit identities for this environment: unit name -> service account email."
  value       = { for name, m in module.agent_identity : name => m.email }
}
