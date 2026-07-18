#!/usr/bin/env bash
# Per-tenant Grafana org + pinned datasource provisioning (ADR-0024 D24-4) — a demo SCRIPT,
# not Terraform: the Terraform Grafana provider is the activation path (D24-5); this is the
# local/dev stand-in, exactly like scripts/temporal/create-namespaces.sh (ADR-0019 precedent).
#
# Data-driven from the LIVE tenant-labeled namespaces — the same signal the Gatekeeper
# constraints trust. Only Terraform stamps that label, so this cannot drift from the registry.
# Idempotent: existing orgs are kept; the datasource is created-or-updated so the pinned
# namespace parameter always converges to the namespace name.
#
# The datasource is the isolation seam: url -> prom-label-proxy, and
# jsonData.customQueryParameters pins `namespace=<tenant>` onto every query it sends. Tenant
# users must never be org Admin (they could re-pin the datasource) — asserted by the ADR-0024
# verification battery, not assumed.
#
# Orphan orgs (org exists, namespace gone — an offboarded tenant) are WARNED about by default;
# `--prune` deletes them (the ADR-0024 offboard follow-on, closed by ADR-0026: the offboard
# runbook runs this with --prune after the namespace is gone). Never automatic: the same
# deliberate-teardown posture as the offboard pipeline itself — a missing namespace could also
# be a half-broken cluster, so a human passes the flag.
#
# Prerequisites: the `grafana-admin` Secret exists (human-pre-created, runbook) and the
# grafana Deployment is Ready.
#
# Usage: scripts/grafana/provision-orgs.sh [kind-context] [--prune]   (default: kind-runtime-dev)
set -euo pipefail

CONTEXT="kind-runtime-dev"
PRUNE=false
for arg in "$@"; do
  case "${arg}" in
    --prune) PRUNE=true ;;
    *) CONTEXT="${arg}" ;;
  esac
done
LOCAL_PORT=13000 # unlikely to collide with a local Grafana on 3000

command -v curl >/dev/null || { echo "ERROR: curl is required" >&2; exit 1; }

ADMIN_PASS=$(kubectl --context "${CONTEXT}" -n platform-system get secret grafana-admin \
  -o jsonpath='{.data.admin-password}' | base64 -d)
[ -n "${ADMIN_PASS}" ] || { echo "ERROR: grafana-admin Secret missing or empty (see runbook)" >&2; exit 1; }

kubectl --context "${CONTEXT}" -n platform-system port-forward svc/grafana "${LOCAL_PORT}:3000" \
  >/tmp/grafana-port-forward.log 2>&1 &
PF_PID=$!
trap 'kill "${PF_PID}" 2>/dev/null || true' EXIT

BASE="http://localhost:${LOCAL_PORT}"
AUTH="admin:${ADMIN_PASS}"

# Wait for the forwarded port + a healthy Grafana rather than a fixed sleep.
for _ in $(seq 1 30); do
  curl -sf -u "${AUTH}" "${BASE}/api/health" >/dev/null 2>&1 && break
  sleep 1
done
curl -sf -u "${AUTH}" "${BASE}/api/health" >/dev/null || { echo "ERROR: Grafana not reachable/healthy" >&2; exit 1; }

# gapi <method> <path> [json-body] — admin-authenticated Grafana API call; prints the body,
# returns non-zero on HTTP >= 400 (curl -f), EXCEPT 404 checks which callers do explicitly.
gapi() {
  local method=$1 path=$2 body=${3:-}
  if [ -n "${body}" ]; then
    curl -sf -u "${AUTH}" -X "${method}" -H "Content-Type: application/json" \
      ${ORG_HEADER:+-H "X-Grafana-Org-Id: ${ORG_HEADER}"} -d "${body}" "${BASE}${path}"
  else
    curl -sf -u "${AUTH}" -X "${method}" \
      ${ORG_HEADER:+-H "X-Grafana-Org-Id: ${ORG_HEADER}"} "${BASE}${path}"
  fi
}

namespaces=$(kubectl --context "${CONTEXT}" get ns -l tenant \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
[ -n "${namespaces}" ] || { echo "no tenant-labeled namespaces on this cluster — nothing to do"; exit 0; }

provisioned=""
while IFS= read -r ns; do
  [ -z "${ns}" ] && continue
  provisioned="${provisioned} ${ns}"

  # Org: get-by-name, create if absent.
  if org_json=$(ORG_HEADER= gapi GET "/api/orgs/name/${ns}" 2>/dev/null); then
    org_id=$(echo "${org_json}" | ruby -rjson -e 'puts JSON.parse(STDIN.read)["id"]')
    echo "org ${ns}: already exists (id ${org_id}), skipping create"
  else
    org_id=$(ORG_HEADER= gapi POST "/api/orgs" "{\"name\":\"${ns}\"}" \
      | ruby -rjson -e 'puts JSON.parse(STDIN.read)["orgId"]')
    echo "org ${ns}: created (id ${org_id})"
  fi

  # Datasource inside the org: create-or-update so the pinned parameter always converges.
  ds_body=$(ruby -rjson -e "puts JSON.generate({
    name: 'tenant-metrics', type: 'prometheus', access: 'proxy',
    url: 'http://prom-label-proxy.platform-system.svc.cluster.local:8080',
    isDefault: true,
    jsonData: { httpMethod: 'POST', customQueryParameters: 'namespace=${ns}' }
  })")
  if ds_json=$(ORG_HEADER=${org_id} gapi GET "/api/datasources/name/tenant-metrics" 2>/dev/null); then
    ds_id=$(echo "${ds_json}" | ruby -rjson -e 'puts JSON.parse(STDIN.read)["id"]')
    ORG_HEADER=${org_id} gapi PUT "/api/datasources/${ds_id}" "${ds_body}" >/dev/null
    echo "org ${ns}: datasource tenant-metrics converged (namespace=${ns})"
  else
    ORG_HEADER=${org_id} gapi POST "/api/datasources" "${ds_body}" >/dev/null
    echo "org ${ns}: datasource tenant-metrics created (namespace=${ns})"
  fi
done <<< "${namespaces}"

# Orphan handling: orgs (other than the default Main Org, id 1) with no matching namespace —
# warn by default, delete under --prune (org deletion removes its datasources and memberships;
# dashboards in an offboarded tenant's org are tenant-owned residue, covered by the offboard
# runbook's retention step).
orphans=$(ORG_HEADER= gapi GET "/api/orgs" | ruby -rjson -e '
  provisioned = ARGV[0].split
  JSON.parse(STDIN.read).each do |o|
    next if o["id"] == 1 || provisioned.include?(o["name"])
    puts "#{o["id"]} #{o["name"]}"
  end' "${provisioned}")

if [ -n "${orphans}" ]; then
  while IFS=' ' read -r org_id org_name; do
    if [ "${PRUNE}" = true ]; then
      ORG_HEADER= gapi DELETE "/api/orgs/${org_id}" >/dev/null
      echo "org ${org_name} (id ${org_id}): PRUNED — no tenant namespace (offboarded)"
    else
      echo "WARNING: org ${org_name} (id ${org_id}) has no tenant namespace — offboarded tenant? Re-run with --prune to delete (ADR-0026)." >&2
    fi
  done <<< "${orphans}"
fi

echo "grafana orgs OK"
