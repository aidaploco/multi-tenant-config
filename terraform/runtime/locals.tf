locals {
  project_id = "runtime-${var.environment}"

  labels = {
    tenant              = "platform"
    environment         = var.environment
    data_classification = "internal"
  }

  # Distinct, non-overlapping RFC1918 ranges per environment, so the runtime VPCs could ever be
  # peered without collision. Primary = nodes; secondaries = VPC-native pods/services.
  # `master` is the /28 for the GKE private control plane; kept clear of the 10.x VPC ranges.
  cidrs = {
    dev  = { subnet = "10.0.0.0/20", pods = "10.4.0.0/14", services = "10.8.0.0/20", master = "172.16.0.0/28" }
    acc  = { subnet = "10.16.0.0/20", pods = "10.20.0.0/14", services = "10.24.0.0/20", master = "172.16.0.16/28" }
    prod = { subnet = "10.32.0.0/20", pods = "10.36.0.0/14", services = "10.40.0.0/20", master = "172.16.0.32/28" }
  }
  net = local.cidrs[var.environment]
}
