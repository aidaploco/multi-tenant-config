#!/usr/bin/env bash
# Stand up the LOCAL runtime plane (ADR-0018): a kind cluster named runtime-<env> with the
# kind local-registry pattern (localhost:5001 — the image host the rendered payload pins,
# ADR-0017 D17-4), Gatekeeper OSS (standing in for Policy Controller) and Config Sync OSS
# (standing in for the Fleet install) syncing this repo's gitops/ from GitHub main.
#
# CLUSTER_NAME=runtime-<env> on the reconciler-manager is the OSS half of ADR-0017 D17-3:
# it is what makes the payload's `configsync.gke.io/cluster-name-selector` scope per env.
#
# Usage: scripts/kind/up.sh [dev]      (then terraform apply — the script prints the commands)
set -euo pipefail

ENV="${1:-dev}"
CLUSTER="runtime-${ENV}"
REG_NAME="kind-registry"
REG_PORT=5001
CONFIG_SYNC_VERSION="v1.24.1"
GATEKEEPER_VERSION="v3.22.2"
REPO_URL="https://github.com/aidaploco/multi-tenant-config"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# --- 1. Local registry container (idempotent; the kind local-registry pattern) ----------------
if [ "$(docker inspect -f '{{.State.Running}}' "${REG_NAME}" 2>/dev/null || true)" != 'true' ]; then
  docker run -d --restart=always -p "127.0.0.1:${REG_PORT}:5000" \
    --network bridge --name "${REG_NAME}" registry:2
fi

# --- 2. kind cluster wired to trust localhost:5001 --------------------------------------------
if ! kind get clusters 2>/dev/null | grep -qx "${CLUSTER}"; then
  cat <<EOF | kind create cluster --name "${CLUSTER}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry]
      config_path = "/etc/containerd/certs.d"
EOF
fi

REGISTRY_DIR="/etc/containerd/certs.d/localhost:${REG_PORT}"
for node in $(kind get nodes --name "${CLUSTER}"); do
  docker exec "${node}" mkdir -p "${REGISTRY_DIR}"
  cat <<EOF | docker exec -i "${node}" cp /dev/stdin "${REGISTRY_DIR}/hosts.toml"
[host."http://${REG_NAME}:5000"]
EOF
done

if [ "$(docker inspect -f '{{json .NetworkSettings.Networks.kind}}' "${REG_NAME}")" = 'null' ]; then
  docker network connect "kind" "${REG_NAME}"
fi

cat <<EOF | kubectl --context "kind-${CLUSTER}" apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REG_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

# --- 3. Gatekeeper OSS (admission engine under Policy Controller — same constraints) -----------
kubectl --context "kind-${CLUSTER}" apply -f \
  "https://raw.githubusercontent.com/open-policy-agent/gatekeeper/${GATEKEEPER_VERSION}/deploy/gatekeeper.yaml"
kubectl --context "kind-${CLUSTER}" -n gatekeeper-system wait deployment --all \
  --for=condition=Available --timeout=180s

# --- 4. Config Sync OSS, cluster-named for per-env payload scoping (ADR-0017 D17-3) -----------
kubectl --context "kind-${CLUSTER}" apply -f \
  "https://github.com/GoogleContainerTools/config-sync/releases/download/${CONFIG_SYNC_VERSION}/config-sync-manifest.yaml"
kubectl --context "kind-${CLUSTER}" -n config-management-system set env deployment/reconciler-manager \
  "CLUSTER_NAME=${CLUSTER}"
kubectl --context "kind-${CLUSTER}" -n config-management-system wait deployment --all \
  --for=condition=Available --timeout=180s

cat <<EOF | kubectl --context "kind-${CLUSTER}" apply -f -
apiVersion: configsync.gke.io/v1beta1
kind: RootSync
metadata:
  name: root-sync
  namespace: config-management-system
spec:
  sourceFormat: unstructured
  git:
    repo: ${REPO_URL}
    branch: main
    dir: gitops
    auth: none
EOF

# --- 5. Local state for the local plane (the root's declared backend is GCS) ------------------
cat > "${REPO_ROOT}/terraform/tenant-runtime/backend_override.tf" <<'EOF'
# Written by scripts/kind/up.sh — git-ignored. Terraform override file: replaces the GCS
# backend with local state for the kind plane (ADR-0018). Delete to return to cloud mode.
terraform {
  backend "local" {}
}
EOF

echo
echo "kind plane '${CLUSTER}' is up. Next:"
echo "  terraform -chdir=terraform/tenant-runtime init"
echo "  terraform -chdir=terraform/tenant-runtime apply -var environment=${ENV} -var cluster_mode=kind"
echo "Watch Config Sync:  kubectl --context kind-${CLUSTER} get rootsync -n config-management-system root-sync -o yaml"
