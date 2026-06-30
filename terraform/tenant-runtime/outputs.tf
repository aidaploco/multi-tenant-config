output "tenant_namespaces" {
  description = "Tenants given a shared-runtime namespace in this environment."
  value       = keys(local.namespaces)
}
