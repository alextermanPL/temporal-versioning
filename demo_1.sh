#!/bin/bash
set -e

COMMIT_BASELINE="b5c10b2"
COMMIT_BREAKING="07ac58e"
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

start_service() {
  ./gradlew quarkusDev --console=plain > "$LOG" 2>&1 &
  GRADLE_PID=$!
  echo "  PID $GRADLE_PID — logs: tail -f $LOG"
  wait_for_service
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

section "STEP 1 — Baseline: working payment workflow ($COMMIT_BASELINE)"

git checkout "$COMMIT_BASELINE" --quiet
echo "  Checked out baseline commit"

start_service

echo ""
echo "  Starting workflow (will wait 20 min for reservation signal)..."
curl -s -X POST "http://localhost:$PORT/payments" \
  -H "Content-Type: application/json" \
  -d '{"paymentId":"1","amount":100,"currency":"EUR","debtorAccount":"LT001","creditorAccount":"LT002"}' \
  | jq .

echo ""
echo "  Workflow is running and WAITING for reservation signal."

stop_service

# ── Step 2 ────────────────────────────────────────────────────────────────────

section "STEP 2 — Breaking change: fraudCheck inserted before reserveFunds ($COMMIT_BREAKING)"

git checkout "$COMMIT_BREAKING" --quiet
echo "  Checked out breaking-change commit"
echo "  Watch for NonDeterministicException: tail -f $LOG"

start_service

echo ""
echo "  Service is up. The running workflow is now STUCK."
echo "  NonDeterministicException should be visible in logs:"
echo "    expected: 'FraudCheck'  /  actual: 'ReserveFunds'"
echo ""
echo "  Sending reservation signal (workflow is stuck — this will not unblock it)..."
curl -s -X POST "http://localhost:$PORT/payments/1/reservation-result" \
  -H "Content-Type: application/json" \
  -d '{"success": true}' \
  | jq .

section "DONE — run demo_2.sh to apply the getVersion fix"
