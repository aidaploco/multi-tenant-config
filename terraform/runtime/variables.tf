variable "environment" {
  description = "Which environment's runtime plane this is. One runtime project + state per environment."
  type        = string

  validation {
    condition     = contains(["dev", "acc", "prod"], var.environment)
    error_message = "environment must be dev, acc, or prod."
  }
}

variable "billing_account" {
  description = "Billing account for the runtime project."
  type        = string
}

variable "runtime_folder_id" {
  description = "The runtime/ folder these projects are created under (bootstrap output folder_ids.runtime)."
  type        = string
}

variable "region" {
  description = "Region for the runtime network and (later) cluster. Constrained by the resourceLocations org policy."
  type        = string
  default     = "europe-west4"
}
