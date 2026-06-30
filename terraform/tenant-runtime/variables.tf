variable "environment" {
  description = "Which environment's shared cluster to provision tenant namespaces on."
  type        = string

  validation {
    condition     = contains(["dev", "acc", "prod"], var.environment)
    error_message = "environment must be dev, acc, or prod."
  }
}

variable "region" {
  description = "Region (for the google provider)."
  type        = string
  default     = "europe-west4"
}
