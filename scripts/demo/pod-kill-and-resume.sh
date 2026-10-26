#!/usr/bin/env bash
# THE acceptance test (docs/PLAN.md): a durable conversation survives its worker pod being
# killed outright, with zero application-level recovery code — same workflow execution (run ID
# unchanged), context intact, on a real kind cluster with Gatekeeper/exact-KSA/NetworkPolicies
# all live. Runs against Lana (agent-chassis), the platform's reference workload.
#
# Conversation state lives directly in Temporal's own workflow state (ConversationState.history
# — confirmed by reading durable/workflows.py, no external store involved), so durability comes
# entirely from Deployment self-healing + Temporal's history.
#
# History: began as pod-kill-and-resume-agent-chassis.sh, a variant of a
# example-agent demo; example-agent exited the landscape 2026-07-18 (a reference example
# for the app repo, never a platform workload) and the Lana variant became the one canonical
# acceptance test. Updated for Lana 0.3.0's real contract: bearer auth on /v1/messages (D21
# channel auth — the token is read from the pre-created lana-secrets, first pair's token half)
# and live guardrails (the memory probe is support-topical so off_topic doesn't reject it).
#
# Usage: scripts/demo/pod-kill-and-resume.sh [kind-context] [namespace]
set -euo pipefail

CONTEXT="${1:-kind-runtime-dev}"
NS="${2:-abf}"
API_PORT=18001
TEMPORAL_PORT=17233
CONVERSATION_ID=$(ruby -rsecurerandom -e "puts SecureRandom.uuid")
WORKFLOW_ID="conversation-${CONVERSATION_ID}"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; cleanup; exit 1; }

cleanup() {
  [ -n "${API_PF:-}" ] && kill "$API_PF" 2>/dev/null || true
}
trap cleanup EXIT

# D21 channel auth: /v1/messages requires a bearer token once HTTP_BEARER_TOKENS is set
# (all-or-nothing per pod). Format: "token:principal" pairs.
TOKEN=$(kubectl --context "${CONTEXT}" get secret lana-secrets -n "${NS}" \
  -o jsonpath='{.data.HTTP_BEARER_TOKENS}' | base64 -d | cut -d: -f1)
[ -n "${TOKEN}" ] || fail "couldn't read a bearer token from lana-secrets (see the runbook)"

temporal_call() {
  kubectl --context "${CONTEXT}" port-forward -n platform-system svc/temporal-frontend "${TEMPORAL_PORT}:7233" \
    >/tmp/demo-lana-temporal-pf.log 2>&1 &
  local pf=$!
  sleep 3
  "$@"
  local rc=$?
  kill "$pf" 2>/dev/null || true
  wait "$pf" 2>/dev/null || true
  return $rc
}

workflow_run_id() {
  temporal workflow describe --address "localhost:${TEMPORAL_PORT}" --namespace "${NS}-dev" \
    --workflow-id "${WORKFLOW_ID}" -o json 2>/dev/null \
    | ruby -rjson -e 'puts JSON.parse(STDIN.read)["workflowExecutionInfo"]["execution"]["runId"]'
}

poller_registered() {
  temporal task-queue describe --address "localhost:${TEMPORAL_PORT}" --namespace "${NS}-dev" \
    --task-queue lana 2>/dev/null | grep "${NEW_POD}" >/dev/null
}

send_message() {
  curl -sf -X POST "http://localhost:${API_PORT}/v1/messages" \
    -H 'Content-Type: application/json' -H "Authorization: Bearer ${TOKEN}" \
    -d "{\"conversation_id\": \"${CONVERSATION_ID}\", \"message\": $1}"
}

echo "=== conversation ${CONVERSATION_ID} / workflow ${WORKFLOW_ID} ==="

kubectl --context "${CONTEXT}" port-forward -n "${NS}" svc/lana-api "${API_PORT}:8000" \
  >/tmp/demo-lana-api-pf.log 2>&1 &
API_PF=$!

for _ in $(seq 1 20); do
  curl -sf "http://localhost:${API_PORT}/healthz" >/dev/null 2>&1 && break
  sleep 1
done

echo "--- turn 1: establishing context (support-topical, so the off_topic guardrail admits it) ---"
TURN1=$(send_message "\"For my support ticket, please note my order number: ORD-4471. Just acknowledge briefly.\"")
echo "agent: $(echo "$TURN1" | ruby -rjson -e 'puts JSON.parse(STDIN.read)["content"]')"

RUN_ID_BEFORE=$(temporal_call workflow_run_id)
echo "workflow run ID before kill: ${RUN_ID_BEFORE}"
[ -n "${RUN_ID_BEFORE}" ] || fail "couldn't read the workflow's run ID before the kill"

OLD_POD=$(kubectl --context "${CONTEXT}" get pod -n "${NS}" -l app=lana-worker -o jsonpath='{.items[0].metadata.name}')
echo "--- killing worker pod ${OLD_POD} ---"
kubectl --context "${CONTEXT}" delete pod -n "${NS}" "${OLD_POD}" --wait=false

echo "--- waiting for a replacement pod ---"
for _ in $(seq 1 40); do
  NEW_POD=$(kubectl --context "${CONTEXT}" get pod -n "${NS}" -l app=lana-worker \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -n "${NEW_POD}" ] && [ "${NEW_POD}" != "${OLD_POD}" ]; then
    READY=$(kubectl --context "${CONTEXT}" get pod -n "${NS}" "${NEW_POD}" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo false)
    [ "${READY}" = "true" ] && break
  fi
  sleep 2
done
[ "${READY:-false}" = "true" ] || fail "replacement worker pod never became Ready"
echo "replacement pod: ${NEW_POD}"

echo "--- confirming it re-registered as a poller ---"
REGISTERED=false
for _ in $(seq 1 40); do
  if temporal_call poller_registered; then
    REGISTERED=true
    break
  fi
  sleep 3
done
[ "${REGISTERED}" = "true" ] || fail "new pod never appeared as a poller on lana"
pass "new worker pod is polling lana"

echo "--- turn 2: does the SAME conversation remember turn 1, after a full pod replacement? ---"
TURN2=$(send_message "\"What order number did I give you for my support ticket?\"")
REPLY=$(echo "$TURN2" | ruby -rjson -e 'puts JSON.parse(STDIN.read)["content"]')
echo "agent: ${REPLY}"

RUN_ID_AFTER=$(temporal_call workflow_run_id)
echo "workflow run ID after kill:  ${RUN_ID_AFTER}"

[ "${RUN_ID_BEFORE}" = "${RUN_ID_AFTER}" ] || fail "run ID changed — this was a NEW workflow, not a resumed one"
pass "same workflow execution before and after the pod kill (run ID unchanged)"

echo "${REPLY}" | grep -qi "ORD-4471" \
  && pass "the agent correctly remembered context from before the pod was killed" \
  || fail "the agent's reply didn't mention the order number from turn 1 — context was lost"

echo
echo "=== ACCEPTANCE TEST PASSED: conversation ${CONVERSATION_ID} survived a full worker pod replacement ==="
