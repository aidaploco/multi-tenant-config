#!/usr/bin/env bash
# The D18 kind-cluster gate for ai-employees-core (their design record, not this platform's
# ADRs): the same acceptance test as scripts/demo/pod-kill-and-resume.sh, adapted for this
# chassis's actual HTTP contract (POST /v1/messages, not /api/v1/chat; conversation_id, not
# session_id; response field is "content", not "message"). A dedicated variant rather than a
# parameterized version of the cs-agent script — flagged as the expected cost when this gate
# was designed (ADR-0021 / D18's own record), not a surprise.
#
# What this proves: the walking-skeleton role (echo + introspection, no memory substrate, no
# guardrails) survives its worker pod being killed outright — the SAME workflow execution (run
# ID unchanged) still holds conversation state kept directly in Temporal's own workflow state
# (ConversationState.history — confirmed by reading durable/workflows.py directly, no external
# store involved), on a real kind cluster with Gatekeeper/exact-KSA/Workload-Identity all live.
#
# Usage: scripts/demo/pod-kill-and-resume-ai-employees-core.sh [kind-context] [namespace]
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

temporal_call() {
  kubectl --context "${CONTEXT}" port-forward -n platform-system svc/temporal-frontend "${TEMPORAL_PORT}:7233" \
    >/tmp/demo-aiemp-temporal-pf.log 2>&1 &
  local pf=$!
  sleep 3
  "$@"
  local rc=$?
  kill "$pf" 2>/dev/null || true
  wait "$pf" 2>/dev/null || true
  return $rc
}

workflow_run_id() {
  temporal workflow describe --address "localhost:${TEMPORAL_PORT}" --namespace abf-dev \
    --workflow-id "${WORKFLOW_ID}" -o json 2>/dev/null \
    | ruby -rjson -e 'puts JSON.parse(STDIN.read)["workflowExecutionInfo"]["execution"]["runId"]'
}

poller_registered() {
  temporal task-queue describe --address "localhost:${TEMPORAL_PORT}" --namespace abf-dev \
    --task-queue ai-employee 2>/dev/null | grep -q "${NEW_POD}"
}

echo "=== conversation ${CONVERSATION_ID} / workflow ${WORKFLOW_ID} ==="

kubectl --context "${CONTEXT}" port-forward -n "${NS}" svc/ai-employees-core-api "${API_PORT}:8000" \
  >/tmp/demo-aiemp-api-pf.log 2>&1 &
API_PF=$!

for _ in $(seq 1 20); do
  curl -sf "http://localhost:${API_PORT}/healthz" >/dev/null 2>&1 && break
  sleep 1
done

echo "--- turn 1: establishing context (no guardrails on this role — any message is fine) ---"
TURN1=$(curl -sf -X POST "http://localhost:${API_PORT}/v1/messages" -H 'Content-Type: application/json' \
  -d "{\"conversation_id\": \"${CONVERSATION_ID}\", \"message\": \"Remember this word for later: pineapple. Just acknowledge briefly.\"}")
echo "agent: $(echo "$TURN1" | ruby -rjson -e 'puts JSON.parse(STDIN.read)["content"]')"

RUN_ID_BEFORE=$(temporal_call workflow_run_id)
echo "workflow run ID before kill: ${RUN_ID_BEFORE}"
[ -n "${RUN_ID_BEFORE}" ] || fail "couldn't read the workflow's run ID before the kill"

OLD_POD=$(kubectl --context "${CONTEXT}" get pod -n "${NS}" -l app=ai-employees-core-worker -o jsonpath='{.items[0].metadata.name}')
echo "--- killing worker pod ${OLD_POD} ---"
kubectl --context "${CONTEXT}" delete pod -n "${NS}" "${OLD_POD}" --wait=false

echo "--- waiting for a replacement pod ---"
for _ in $(seq 1 40); do
  NEW_POD=$(kubectl --context "${CONTEXT}" get pod -n "${NS}" -l app=ai-employees-core-worker \
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
[ "${REGISTERED}" = "true" ] || fail "new pod never appeared as a poller on ai-employee"
pass "new worker pod is polling ai-employee"

echo "--- turn 2: does the SAME conversation remember turn 1, after a full pod replacement? ---"
TURN2=$(curl -sf -X POST "http://localhost:${API_PORT}/v1/messages" -H 'Content-Type: application/json' \
  -d "{\"conversation_id\": \"${CONVERSATION_ID}\", \"message\": \"What word did I ask you to remember?\"}")
REPLY=$(echo "$TURN2" | ruby -rjson -e 'puts JSON.parse(STDIN.read)["content"]')
echo "agent: ${REPLY}"

RUN_ID_AFTER=$(temporal_call workflow_run_id)
echo "workflow run ID after kill:  ${RUN_ID_AFTER}"

[ "${RUN_ID_BEFORE}" = "${RUN_ID_AFTER}" ] || fail "run ID changed — this was a NEW workflow, not a resumed one"
pass "same workflow execution before and after the pod kill (run ID unchanged)"

echo "${REPLY}" | grep -qi "pineapple" \
  && pass "the agent correctly remembered context from before the pod was killed" \
  || fail "the agent's reply didn't mention the word from turn 1 — context was lost"

echo
echo "=== D18 KIND-CLUSTER GATE PASSED: conversation ${CONVERSATION_ID} survived a full worker pod replacement ==="
