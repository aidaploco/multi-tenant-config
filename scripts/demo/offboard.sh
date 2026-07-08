#!/usr/bin/env bash
# The other half of the platform's acceptance test (docs/PLAN.md): clean tenant offboard, in the
# ORDER the design depends on — payload pruned (Config Sync) BEFORE the namespace is destroyed
# (Terraform). Getting this backwards is exactly the dual-ownership bug ADR-0012 exists to
# prevent (Config Sync fighting Terraform over the same objects).
#
# Uses a throwaway tenant (demo-offboard) rather than real abf/helix data — commits an onboard,
# proves the tenant is live, commits the offboard, proves the ordering held, and leaves no trace
# in the registry afterward. Every step is a REAL commit/push/apply against the actual repo and
# cluster, same as a real onboard/offboard would be — this is the scripted demo, not a simulation.
#
# Usage: scripts/demo/offboard.sh [kind-context]
set -euo pipefail

CONTEXT="${1:-kind-runtime-dev}"
NS="demo-offboard"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TENANT_FILE="${REPO_ROOT}/tenants/${NS}.yaml"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; exit 1; }

wait_for_sync() {
  local commit="$1"
  for _ in $(seq 1 20); do
    synced=$(kubectl --context "${CONTEXT}" get rootsync -n config-management-system root-sync \
      -o jsonpath='{.status.sync.commit}' 2>/dev/null || true)
    [[ "${synced}" == "${commit}"* ]] && return 0
    sleep 5
  done
  return 1
}

cd "${REPO_ROOT}"

echo "=== 1. Onboard the throwaway tenant ==="
cat > "${TENANT_FILE}" <<EOF
# THROWAWAY — written and removed by scripts/demo/offboard.sh. Never hand-edit.
slug: ${NS}
display_name: "Offboard Demo"
owner_group: demo-offboard@company.com
data_classification: internal
cmek_location: europe-west4
defaults:
  layers:
    compute: { opt_in: true, isolation: shared }
  units:
    echo: { type: agent-unit, version: 0.1.0, opt_in: true, image: demo-offboard-echo }
environments:
  dev: {}
EOF

docker tag nginx:alpine "localhost:5001/demo-offboard-echo:0.1.0" 2>/dev/null || true
docker push "localhost:5001/demo-offboard-echo:0.1.0" >/dev/null

ruby scripts/check-registry.rb
ruby scripts/render-payload.rb

echo "--- terraform apply: create the namespace + KSA ---"
terraform -chdir=terraform/tenant-runtime apply -auto-approve -var environment=dev -var cluster_mode=kind >/dev/null
kubectl --context "${CONTEXT}" get namespace "${NS}" >/dev/null 2>&1 || fail "namespace ${NS} was not created"
pass "namespace ${NS} exists"

git add "tenants/${NS}.yaml" gitops/payload
git commit -m "test: onboard throwaway tenant ${NS} to verify offboard ordering (demo)" >/dev/null
git push
COMMIT_SHA=$(git rev-parse HEAD)
echo "onboard commit: ${COMMIT_SHA}"

echo "--- waiting for Config Sync to apply the payload ---"
wait_for_sync "${COMMIT_SHA}" || fail "Config Sync never synced the onboard commit"
for _ in $(seq 1 15); do
  kubectl --context "${CONTEXT}" get deployment echo -n "${NS}" >/dev/null 2>&1 && break
  sleep 3
done
kubectl --context "${CONTEXT}" get deployment echo -n "${NS}" >/dev/null 2>&1 || fail "payload was never applied"
pass "payload (Deployment echo) is live in namespace ${NS}"

echo
echo "=== 2. Offboard: registry removal -> payload pruned -> THEN namespace destroyed ==="
rm "${TENANT_FILE}"
ruby scripts/render-payload.rb

git add -A -- tenants gitops/payload
git commit -m "test: offboard throwaway tenant ${NS} — verifying prune-before-destroy ordering (demo)" >/dev/null
git push
COMMIT_SHA=$(git rev-parse HEAD)
echo "offboard commit: ${COMMIT_SHA}"

echo "--- waiting for Config Sync to prune the payload ---"
wait_for_sync "${COMMIT_SHA}" || fail "Config Sync never synced the offboard commit"
for _ in $(seq 1 15); do
  kubectl --context "${CONTEXT}" get deployment echo -n "${NS}" >/dev/null 2>&1 || break
  sleep 3
done
kubectl --context "${CONTEXT}" get deployment echo -n "${NS}" >/dev/null 2>&1 \
  && fail "payload was not pruned"
pass "payload pruned"

kubectl --context "${CONTEXT}" get namespace "${NS}" >/dev/null 2>&1 \
  || fail "namespace ${NS} disappeared before Terraform destroyed it — ordering violated"
pass "namespace ${NS} still exists — payload was pruned strictly BEFORE the namespace destroy (correct order)"

echo "--- terraform apply: destroy the now-unreferenced namespace ---"
terraform -chdir=terraform/tenant-runtime apply -auto-approve -var environment=dev -var cluster_mode=kind >/dev/null
kubectl --context "${CONTEXT}" get namespace "${NS}" >/dev/null 2>&1 \
  && fail "namespace ${NS} still exists after the destroy apply"
pass "namespace ${NS} destroyed"

echo
echo "=== OFFBOARD DEMO PASSED: payload pruned before namespace destroyed, registry left clean ==="
