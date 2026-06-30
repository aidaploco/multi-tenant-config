locals {
  project_id = "runtime-${var.environment}"

  labels = {
    tenant              = "platform"
    environment         = var.environment
    data_classification = "internal"
  }

  # Distinct, non-overlapping RFC1918 ranges per environment, so the runtime VPCs could ever be
  # peered without collision. Primary = nodes; secondaries = VPC-native pods/services.
  cidrs = {
    dev  = { subnet = "10.0.0.0/20", pods = "10.4.0.0/14", services = "10.8.0.0/20" }
    acc  = { subnet = "10.16.0.0/20", pods = "10.20.0.0/14", services = "10.24.0.0/20" }
    prod = { subnet = "10.32.0.0/20", pods = "10.36.0.0/14", services = "10.40.0.0/20" }
  }
  net = local.cidrs[var.environment]
}
