#!/usr/bin/env bash
# Per-(tenant, environment) Temporal namespace provisioning (ADR-0016 D16-3, ADR-0019) — a demo
# SCRIPT, not a Terraform module: the `temporal-namespace` module stays gated on Temporal Cloud
# (D16-4, "build when the first workload consumes it"), which hasn't happened yet. This is the
# interim, local/dev provisioning path standing in for it, data-driven from the SAME registry.
#
# Namespace name = "<tenant>-<environment>" (matches TEMPORAL_NAMESPACE in the rendered payload,
# scripts/render-payload.rb, and the "<slug>-<env>" convention used for GCP project IDs
# elsewhere). Idempotent: skips namespaces that already exist.
#
# Prerequisite: the `temporal` CLI (`brew install temporal`) — same binary as the dev server
# image, different invocation (this talks to a remote frontend, not `server start-dev`).
#
# Usage: scripts/temporal/create-namespaces.sh [kind-context]   (default: kind-runtime-dev)
set -euo pipefail

CONTEXT="${1:-kind-runtime-dev}"
LOCAL_PORT=17233 # unlikely to collide; avoids clobbering a real 7233 already in use locally
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

command -v temporal >/dev/null || { echo "ERROR: the 'temporal' CLI is required (brew install temporal)" >&2; exit 1; }

kubectl --context "${CONTEXT}" -n platform-system port-forward svc/temporal-frontend "${LOCAL_PORT}:7233" \
  >/tmp/temporal-port-forward.log 2>&1 &
PF_PID=$!
trap 'kill "${PF_PID}" 2>/dev/null || true' EXIT

# Wait for the forwarded port rather than a fixed sleep — kubectl needs a moment to establish it.
for _ in $(seq 1 20); do
  temporal operator namespace list --address "localhost:${LOCAL_PORT}" >/dev/null 2>&1 && break
  sleep 1
done

pairs_json=$(ruby "${REPO_ROOT}/scripts/list-tenant-envs.rb")
pairs=$(echo "${pairs_json}" | ruby -rjson -e 'JSON.parse(STDIN.read)["_pairs"].each { |p| puts "#{p["tenant"]}-#{p["environment"]}" }')

echo "${pairs}" | while IFS= read -r ns; do
  [ -z "${ns}" ] && continue
  if temporal operator namespace describe --address "localhost:${LOCAL_PORT}" --namespace "${ns}" >/dev/null 2>&1; then
    echo "namespace ${ns}: already exists, skipping"
  else
    temporal operator namespace create --address "localhost:${LOCAL_PORT}" --namespace "${ns}" \
      --retention 24h --description "ADR-0016 D16-3 — one namespace per (tenant, environment), demo-provisioned"
    echo "namespace ${ns}: created"
  fi
done
