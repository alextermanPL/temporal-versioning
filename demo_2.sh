#!/bin/bash
set -e

COMMIT_FIX="52a7e69"
PORT=9090
LOG=/tmp/quarkus-demo.log
GRADLE_PID=""

# ── Helpers ───────────────────────────────────────────────────────────────────

wait_for_service() {
  echo "  Waiting for service on :$PORT..."
  for i in $(seq 1 60); do
    if curl -s "http://localhost:$PORT/q/health/live" > /dev/null 2>&1; then
      echo "  Service ready."
      return 0
    fi
    sleep 2
  done
  echo "  ERROR: service did not start within 2 minutes"
  exit 1
}

stop_service() {
  echo "  Stopping service..."
  QUARKUS_PID=$(lsof -ti tcp:$PORT 2>/dev/null) || true
  [ -n "$QUARKUS_PID" ] && kill "$QUARKUS_PID" 2>/dev/null || true
  [ -n "$GRADLE_PID" ]  && kill "$GRADLE_PID"  2>/dev/null || true
  sleep 3
  echo "  Service stopped."
}

section() {
  echo ""
  echo "══════════════════════════════════════════════════"
  echo "  $1"
  echo "══════════════════════════════════════════════════"
}

# ── Main ──────────────────────────────────────────────────────────────────────

section "STEP 3 — Fix: Workflow.getVersion() patch ($COMMIT_FIX)"

stop_service

git checkout "$COMMIT_FIX" --quiet
echo "  Checked out version-fix commit"
echo "  Logs: tail -f $LOG"

./gradlew quarkusDev --console=plain > "$LOG" 2>&1 &
GRADLE_PID=$!
wait_for_service

echo ""
echo "  Sending reservation signal..."
echo "  The stuck workflow should now:"
echo "    - read DEFAULT_VERSION from the marker → skip fraudCheck"
echo "    - resume from reserveFunds → transfer → publishCompleted"
echo ""

curl -s -X POST "http://localhost:$PORT/payments/1/reservation-result" \
  -H "Content-Type: application/json" \
  -d '{"success": true}' \
  | jq .

section "DONE — check Temporal UI at http://localhost:8088"
echo "  The workflow should have completed with status COMPLETED."
echo "  New workflows started now will run fraudCheck (version=1)."
echo "  Old workflows that were stuck are now unblocked (version=DEFAULT_VERSION)."
echo ""

git checkout main --quiet
echo "  Restored to main branch."
