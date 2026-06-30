# Same keyless model as the tenant root (ADR-0001 D5/D12): in CI, GitHub OIDC -> WIF -> the
# applier SA. Local validation uses ADC; no apply is run locally.
provider "google" {
  region = var.region
}
