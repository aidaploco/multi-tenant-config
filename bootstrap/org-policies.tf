# Day-zero Org Policies (ADR-0001 D4/D5/D8). These are the RUNTIME backstop: the cloud itself
# refuses to create a violating resource, regardless of what Terraform or a console click asks
# for. They attach at the org root so every folder and project inherits them from minute one —
# the whole point is that an insecure resource cannot be created by accident, ever.
#
# OPA (in CI) is the pre-flight half of the same defence; these are the floor underneath it.

locals {
  org = "organizations/${var.org_id}"
}

# --- D5: no service-account JSON keys, ever. Nothing to leak. ---
resource "google_org_policy_policy" "disable_sa_keys" {
  name   = "${local.org}/policies/iam.disableServiceAccountKeyCreation"
  parent = local.org
  spec {
    rules { enforce = "TRUE" }
  }
}

# --- D4: no external IPs on VMs. Resources are private by default. ---
resource "google_org_policy_policy" "no_external_ip" {
  name   = "${local.org}/policies/compute.vmExternalIpAccess"
  parent = local.org
  spec {
    rules { deny_all = "TRUE" }
  }
}

# --- D4: no auto-created default network (which ships with permissive firewall rules). ---
resource "google_org_policy_policy" "skip_default_network" {
  name   = "${local.org}/policies/compute.skipDefaultNetworkCreation"
  parent = local.org
  spec {
    rules { enforce = "TRUE" }
  }
}

# --- D8: data residency. Resources may only be created in approved locations. Matches the
#         approved_locations set in the OPA policy (europe-west4, eu). ---
resource "google_org_policy_policy" "resource_locations" {
  name   = "${local.org}/policies/gcp.resourceLocations"
  parent = local.org
  spec {
    rules {
      values {
        allowed_values = ["in:europe-west4-locations", "in:eu-locations"]
      }
    }
  }
}

# --- Tenant isolation backstop: access may only be granted to identities in our own org's
#     directory, never to arbitrary external Google accounts. ---
resource "google_org_policy_policy" "allowed_domains" {
  name   = "${local.org}/policies/iam.allowedPolicyMemberDomains"
  parent = local.org
  spec {
    rules {
      values {
        allowed_values = ["is:${var.allowed_domain_customer_id}"]
      }
    }
  }
}
