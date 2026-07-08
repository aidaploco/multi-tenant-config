#!/usr/bin/env bash
# THE acceptance test for the whole platform effort (docs/PLAN.md): onboard -> deploy -> durable
# conversation -> kill the worker pod mid-conversation -> the SAME workflow resumes on a
# replacement pod with no loss of context. Runs against the REAL cs-agent-api/cs-agent-worker
# units (ADR-0020) on the local kind plane (ADR-0018) — real OpenAI calls, real Postgres/Redis.
#
# What "resume" means here, concretely (not caught mid-activity): ConversationWorkflow's turns
# run request/response through an update-with-start call from the API — a genuine "kill mid a
# single LLM call" recovery would wait out the 120s activity timeout (no heartbeating is wired
# yet) and make for a slow, unconvincing demo. The meaningful proof, and what the platform is
# actually responsible for, is: does the SAME workflow execution — same conversation, same
# memory — survive the worker POD being destroyed and replaced, with the platform's own
# mechanisms (Deployment self-healing, Temporal's durable history) doing all the work with zero
# application-level recovery code. That's what this script proves.
#
# Each Temporal CLI call gets its OWN short-lived port-forward rather than sharing one for the
# whole script: a single long-lived kubectl port-forward under Docker Desktop drops individual
# rapid-fire connections often enough ("connection reset by peer") to make a tight retry loop
# against it unreliable, even though the tunnel process itself survives.
#
# Usage: scripts/demo/pod-kill-and-resume.sh [kind-context] [namespace]
set -euo pipefail

CONTEXT="${1:-kind-runtime-dev}"
NS="${2:-abf}"
API_PORT=18000
TEMPORAL_PORT=17233
SESSION_ID=$(ruby -rsecurerandom -e "puts SecureRandom.uuid")
WORKFLOW_ID="conversation-${SESSION_ID}"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; cleanup; exit 1; }

cleanup() {
  [ -n "${API_PF:-}" ] && kill "$API_PF" 2>/dev/null || true
}
trap cleanup EXIT

# Runs one Temporal CLI call against a fresh, single-use port-forward: "$@" is the command,
# with TEMPORAL_PORT already available to it. Isolates each call from the others' connection
# state instead of sharing one tunnel across the whole script.
temporal_call() {
  kubectl --context "${CONTEXT}" port-forward -n platform-system svc/temporal-frontend "${TEMPORAL_PORT}:7233" \
    >/tmp/demo-temporal-pf.log 2>&1 &
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
    --task-queue cs-agent 2>/dev/null | grep -q "${NEW_POD}"
}

echo "=== session ${SESSION_ID} / workflow ${WORKFLOW_ID} ==="

kubectl --context "${CONTEXT}" port-forward -n "${NS}" svc/cs-agent-api "${API_PORT}:8000" \
  >/tmp/demo-api-pf.log 2>&1 &
API_PF=$!

for _ in $(seq 1 20); do
  curl -sf "http://localhost:${API_PORT}/api/v1/agents" >/dev/null 2>&1 && break
  sleep 1
done

echo "--- turn 1: establishing context ---"
TURN1=$(curl -sf -X POST "http://localhost:${API_PORT}/api/v1/chat" -H 'Content-Type: application/json' \
  -d "{\"session_id\": \"${SESSION_ID}\", \"message\": \"Please note my order number for this support conversation: BL-48219. Just acknowledge, no questions.\"}")
echo "agent: $(echo "$TURN1" | ruby -rjson -e 'puts JSON.parse(STDIN.read)["message"]')"

RUN_ID_BEFORE=$(temporal_call workflow_run_id)
echo "workflow run ID before kill: ${RUN_ID_BEFORE}"
[ -n "${RUN_ID_BEFORE}" ] || fail "couldn't read the workflow's run ID before the kill"

OLD_POD=$(kubectl --context "${CONTEXT}" get pod -n "${NS}" -l app=cs-agent-worker -o jsonpath='{.items[0].metadata.name}')
echo "--- killing worker pod ${OLD_POD} ---"
kubectl --context "${CONTEXT}" delete pod -n "${NS}" "${OLD_POD}" --wait=false

echo "--- waiting for a replacement pod ---"
for _ in $(seq 1 40); do
  NEW_POD=$(kubectl --context "${CONTEXT}" get pod -n "${NS}" -l app=cs-agent-worker \
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
for _ in $(seq 1 12); do
  if temporal_call poller_registered; then
    REGISTERED=true
    break
  fi
  sleep 3
done
[ "${REGISTERED}" = "true" ] || fail "new pod never appeared as a poller on the task queue"
pass "new worker pod is polling cs-agent"

echo "--- turn 2: does the SAME conversation remember turn 1, after a full pod replacement? ---"
TURN2=$(curl -sf -X POST "http://localhost:${API_PORT}/api/v1/chat" -H 'Content-Type: application/json' \
  -d "{\"session_id\": \"${SESSION_ID}\", \"message\": \"What order number did I give you earlier in this conversation?\"}")
REPLY=$(echo "$TURN2" | ruby -rjson -e 'puts JSON.parse(STDIN.read)["message"]')
echo "agent: ${REPLY}"

RUN_ID_AFTER=$(temporal_call workflow_run_id)
echo "workflow run ID after kill:  ${RUN_ID_AFTER}"

[ "${RUN_ID_BEFORE}" = "${RUN_ID_AFTER}" ] || fail "run ID changed — this was a NEW workflow, not a resumed one"
pass "same workflow execution before and after the pod kill (run ID unchanged)"

echo "${REPLY}" | grep -qi "BL-48219" \
  && pass "the agent correctly remembered context from before the pod was killed" \
  || fail "the agent's reply didn't mention the order number from turn 1 — context was lost"

echo
echo "=== ACCEPTANCE TEST PASSED: conversation ${SESSION_ID} survived a full worker pod replacement ==="
