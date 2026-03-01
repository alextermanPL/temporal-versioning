#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# demo_strategy2.sh  — Strategy 2: Worker Deployments (Pinned)
#
# Shows that when you add a breaking change (fraudCheck before reserveFunds),
# you DON'T need getVersion() — old workflows stay pinned to the old worker,
# new workflows go to the new worker.
#
# Requires:
#   - Docker Compose stack running (Temporal + Wiremock)
#   - Two terminal windows (or tmux) — this script guides you step by step
#   - Branch: feat/strategy-2-worker-versioning (breaking change without getVersion)
#   - Baseline code in commit b5c10b2 (no fraudCheck)
#
# Two workers run simultaneously on different ports:
#   v1 worker  →  port 9090  (baseline code, no fraudCheck)
#   v2 worker  →  port 9091  (breaking code, fraudCheck added)
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

TEMPORAL_CLI="docker exec temporal-admin-tools temporal"
TASK_QUEUE="payment-queue"
NAMESPACE="default"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

pause() { echo -e "${YELLOW}▶ $1${NC}"; read -r -p "  Press ENTER to continue..."; }
info()  { echo -e "${CYAN}ℹ  $1${NC}"; }
ok()    { echo -e "${GREEN}✔  $1${NC}"; }
warn()  { echo -e "${RED}✘  $1${NC}"; }

# ─── STEP 0: sanity checks ───────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════"
echo "  Strategy 2 Demo: Worker Deployments (Pinned versioning)"
echo "════════════════════════════════════════════════════════════"

if ! docker ps --format '{{.Names}}' | grep -q temporal-admin-tools; then
  warn "Temporal is not running. Start it first: docker compose up -d"
  exit 1
fi
ok "Temporal is running"

# ─── STEP 1: build JAR for v1 (baseline — no fraudCheck) ────────────────────
echo ""
pause "STEP 1 — Build v1 JAR (baseline code, no fraudCheck)"

info "Stashing current changes and checking out v1 commit (b5c10b2)..."
git stash
git checkout b5c10b2 -- src/

info "Building v1 JAR..."
./gradlew quarkusBuild -q
mkdir -p build-v1
cp -r build/quarkus-app build-v1/quarkus-app
ok "v1 JAR built → build-v1/"

# Restore the strategy-2 code
git checkout HEAD -- src/
git stash pop 2>/dev/null || true

# ─── STEP 2: build JAR for v2 (this branch — fraudCheck added) ──────────────
echo ""
pause "STEP 2 — Build v2 JAR (breaking change: fraudCheck before reserveFunds)"

info "Building v2 JAR..."
./gradlew quarkusBuild -q
mkdir -p build-v2
cp -r build/quarkus-app build-v2/quarkus-app
ok "v2 JAR built → build-v2/"

# ─── STEP 3: register v1 build ID with Temporal ─────────────────────────────
echo ""
pause "STEP 3 — Register build ID 'v1' with Temporal as the current default"

$TEMPORAL_CLI task-queue update-build-ids \
  --namespace "$NAMESPACE" \
  --task-queue "$TASK_QUEUE" \
  --new-build-id-in-new-default-set v1

ok "Build ID 'v1' registered as default"
info "Verify: docker exec temporal-admin-tools temporal task-queue get-build-ids --task-queue $TASK_QUEUE --namespace $NAMESPACE"

# ─── STEP 4: start v1 worker ────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════"
pause "STEP 4 — Start v1 worker (port 9090, build-id=v1)"
echo ""
info "Starting v1 worker in the background..."

java \
  -Dquarkus.http.port=9090 \
  -Dquarkus.temporal.worker.payment-queue.build-id=v1 \
  -jar build-v1/quarkus-app/quarkus-run.jar \
  > /tmp/worker-v1.log 2>&1 &

V1_PID=$!
echo "$V1_PID" > /tmp/worker-v1.pid
info "v1 worker PID: $V1_PID  (logs: /tmp/worker-v1.log)"

info "Waiting for v1 worker to start..."
sleep 5

if kill -0 "$V1_PID" 2>/dev/null; then
  ok "v1 worker is running"
else
  warn "v1 worker failed to start — check /tmp/worker-v1.log"
  exit 1
fi

# ─── STEP 5: start a workflow on v1 ─────────────────────────────────────────
echo ""
pause "STEP 5 — Start payment workflow (will be pinned to v1)"

info "Starting workflow for payment-10 (20-min await — stays on v1)..."
curl -s -X POST http://localhost:9090/payments \
  -H "Content-Type: application/json" \
  -d '{"paymentId":"10","amount":100.00,"currency":"EUR","debtorAccount":"LV01BANK0000000000010","creditorAccount":"LV02BANK0000000000020"}' \
  | python3 -m json.tool 2>/dev/null || true

ok "Workflow payment-10 started — it is now PINNED to build-id v1"
info "Check in Temporal UI → http://localhost:8080 — find payment:10"
info "You should see: no fraudCheck activity (v1 code)"

# ─── STEP 6: register v2 build ID ───────────────────────────────────────────
echo ""
pause "STEP 6 — Register build ID 'v2' as the new default"

$TEMPORAL_CLI task-queue update-build-ids \
  --namespace "$NAMESPACE" \
  --task-queue "$TASK_QUEUE" \
  --new-build-id-in-new-default-set v2

ok "Build ID 'v2' registered as new default"
info "Now: new workflows → v2   |   running workflows → still on v1"

# ─── STEP 7: start v2 worker ────────────────────────────────────────────────
echo ""
pause "STEP 7 — Start v2 worker (port 9091, build-id=v2)"

java \
  -Dquarkus.http.port=9091 \
  -Dquarkus.temporal.worker.payment-queue.build-id=v2 \
  -jar build-v2/quarkus-app/quarkus-run.jar \
  > /tmp/worker-v2.log 2>&1 &

V2_PID=$!
echo "$V2_PID" > /tmp/worker-v2.pid
info "v2 worker PID: $V2_PID  (logs: /tmp/worker-v2.log)"

info "Waiting for v2 worker to start..."
sleep 5

if kill -0 "$V2_PID" 2>/dev/null; then
  ok "v2 worker is running"
else
  warn "v2 worker failed to start — check /tmp/worker-v2.log"
fi

# ─── STEP 8: start a NEW workflow on v2 ─────────────────────────────────────
echo ""
pause "STEP 8 — Start a NEW workflow (will go to v2)"

info "Starting workflow for payment-11 (will run on v2 — has fraudCheck)..."
curl -s -X POST http://localhost:9091/payments \
  -H "Content-Type: application/json" \
  -d '{"paymentId":"11","amount":200.00,"currency":"EUR","debtorAccount":"LV01BANK0000000000010","creditorAccount":"LV02BANK0000000000020"}' \
  | python3 -m json.tool 2>/dev/null || true

ok "Workflow payment-11 started — pinned to build-id v2"
info "In Temporal UI — payment:11 should show fraudCheck activity first"

# ─── STEP 9: signal both workflows ──────────────────────────────────────────
echo ""
pause "STEP 9 — Signal both workflows (reservation result)"

info "Signaling payment-10 (running on v1 — no fraudCheck)..."
curl -s -X POST "http://localhost:9090/payments/10/reservation-result" \
  -H "Content-Type: application/json" \
  -d '{"success":true,"reservationId":"res-10","reason":null}' \
  | python3 -m json.tool 2>/dev/null || true

info "Signaling payment-11 (running on v2 — has fraudCheck)..."
curl -s -X POST "http://localhost:9091/payments/11/reservation-result" \
  -H "Content-Type: application/json" \
  -d '{"success":true,"reservationId":"res-11","reason":null}' \
  | python3 -m json.tool 2>/dev/null || true

# ─── STEP 10: verify ─────────────────────────────────────────────────────────
echo ""
pause "STEP 10 — Verify: both workflows completed, NO NonDeterministicException"

info "Check workflow statuses in Temporal UI → http://localhost:8080"
info ""
info "Expected result:"
info "  payment:10  — COMPLETED  (ran on v1, no fraudCheck, no errors)"
info "  payment:11  — COMPLETED  (ran on v2, fraudCheck executed, no errors)"
info ""
info "KEY INSIGHT: payment:10 used the NEW (breaking) code but did NOT break"
info "because it stayed pinned to the v1 worker. No getVersion() needed!"

# ─── CLEANUP ─────────────────────────────────────────────────────────────────
echo ""
pause "CLEANUP — Stop both workers"

kill "$(cat /tmp/worker-v1.pid 2>/dev/null)" 2>/dev/null && ok "v1 worker stopped" || true
kill "$(cat /tmp/worker-v2.pid 2>/dev/null)" 2>/dev/null && ok "v2 worker stopped" || true
rm -f /tmp/worker-v1.pid /tmp/worker-v2.pid

echo ""
echo "════════════════════════════════════════════════════════════"
ok "Strategy 2 demo complete!"
echo "════════════════════════════════════════════════════════════"
