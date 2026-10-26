variable "org_id" {
  description = "Numeric GCP organization ID (e.g. \"123456789012\"). The root of everything."
  type        = string
}

variable "billing_account" {
  description = "Billing account ID (e.g. \"012345-6789AB-CDEF01\") to attach the management project to."
  type        = string
}

variable "allowed_domain_customer_id" {
  description = <<-EOT
    Cloud Identity / Workspace customer ID (e.g. "C01abc234"), NOT the domain string. Used by the
    iam.allowedPolicyMemberDomains org policy to forbid granting access to outside identities — the
    runtime backstop for tenant isolation (no sharing data with random external accounts).
  EOT
  type        = string
}

variable "github_org" {
  description = "GitHub org/owner that hosts multi-tenant-config (the repo CI runs from)."
  type        = string
}

variable "github_repo" {
  description = "Repository name of multi-tenant-config (without the owner)."
  type        = string
}

variable "management_project_id" {
  description = "Globally-unique project ID for the management project (state + CI identities)."
  type        = string
  default     = "platform-management"
}

variable "state_bucket_name" {
  description = "Globally-unique name for the Terraform state bucket. Defaults to <project>-tfstate."
  type        = string
  default     = null
}

variable "region" {
  description = "Region for the state bucket and KMS keyring. Must satisfy the resourceLocations policy."
  type        = string
  default     = "europe-west4"
}
