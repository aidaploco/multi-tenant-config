#!/usr/bin/env bash
# Tear down the local runtime plane (ADR-0018). Removes the kind cluster, its git-ignored
# backend override AND the local Terraform state (the cluster the state described is gone —
# keeping either would leave a lying backend or lying state). The registry container is kept
# (images survive an up/down cycle); remove it with: docker rm -f kind-registry
set -euo pipefail

ENV="${1:-dev}"
CLUSTER="runtime-${ENV}"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

kind delete cluster --name "${CLUSTER}" 2>/dev/null || true
rm -f "${REPO_ROOT}/terraform/tenant-runtime/backend_override.tf" \
      "${REPO_ROOT}/terraform/tenant-runtime/terraform.tfstate" \
      "${REPO_ROOT}/terraform/tenant-runtime/terraform.tfstate.backup"
echo "kind plane '${CLUSTER}' removed."
