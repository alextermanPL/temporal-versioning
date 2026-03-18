# Temporal Workflow Versioning — Live Demo

This project demonstrates how **ongoing code changes break running Temporal workflows**
and how to fix them safely — all without downtime.

The demo is built around a realistic payment workflow. It shows the problem (a breaking change)
and two different strategies to fix it, each on its own branch.

For a deep-dive on all Temporal versioning strategies, see [VERSIONING.md](./VERSIONING.md).

---

## Repository structure

```
main (baseline)       initial commit: the WF is working
      │
      └── tag: breaking_change   ← fraudCheck inserted, NO fix
               │
               ├── solution/version-sdk      fix: Workflow.getVersion() patch
               │
               └── solution/worker-versioning fix: worker deployments (pinned)
```

| State | What the code does | Effect on running workflows |
|---|---|---|
| `main` | `reserveFunds → transfer → publishCompleted` | ✅ Works |
| `breaking_change` | `fraudCheck` inserted before `reserveFunds`, no fix | 💥 `NonDeterministicException` |
| `solution/version-sdk` | `Workflow.getVersion()` guards `fraudCheck` | ✅ Old WFs replay safely, new WFs run `fraudCheck` |
| `solution/worker-versioning` | Old worker (v1) stays up, new worker (v2) takes new WFs | ✅ No code branching needed |

---

## Prerequisites

- Java 21
- Docker + Docker Compose
- `jq` (`brew install jq`)

---

## Step 0 — Start infrastructure

```bash
docker-compose up -d
```

Starts:
- **Temporal server** on `localhost:7233`
- **Temporal UI** on `http://localhost:8080`
- **PostgreSQL** (Temporal persistence)
- **Wiremock** on `localhost:8089` (mocks the payment bank API)

**Validate:**
```bash
curl -s http://localhost:8089/api/payment/sepa/1 | jq .
# → {"status":"continue"}
```

---

## Demo A — Strategy 1: Workflow.getVersion() patch

### Step 1 — Run baseline → breaking change

```bash
# Ensure you are on the baseline
git checkout main

./demo_1.sh
```

`demo_1.sh` does:
1. Starts the Quarkus worker (logs → `/tmp/quarkus-demo.log`)
2. Starts payment workflow via REST — parks at the reservation signal (60-min wait)
3. Stops the worker
4. Checks out `breaking_change` tag — `fraudCheck` added before `reserveFunds`, no fix
5. Restarts the worker
6. Sends the reservation signal

**What to observe in Temporal UI (`http://localhost:8080`):**

After step 5, within seconds:
```
WorkflowTaskFailed — NonDeterministicException:
  Command COMMAND_TYPE_SCHEDULE_ACTIVITY_TASK doesn't match
  expected: 'FraudCheck'  /  actual: 'ReserveFunds'
```

After step 6, the signal is queued but the workflow stays stuck —
every task attempt fails on replay.

---

### Step 2 — Apply the getVersion fix

```bash
./demo_2.sh
```

`demo_2.sh` does:
1. Stops the broken worker
2. Checks out `solution/version-sdk` branch
3. Restarts the worker
4. Sends the reservation signal again

**How the fix works:**

```kotlin
val version = Workflow.getVersion("addFraudCheck", Workflow.DEFAULT_VERSION, 2)
when (version) {
    Workflow.DEFAULT_VERSION -> {
        // Oldest baseline workflows skip fraud check
    }
    1 -> {
        // Middle-aged workflows run basic fraud check
        activities.fraudCheck(paymentId)
    }
    else -> {
        // New workflows run advanced fraud check
        activities.fraudCheck(paymentId, "advanced")
    }
}
```

- Old workflow (no marker) → `getVersion` returns `DEFAULT_VERSION` → skips `fraudCheck` ✅
- Mid-age workflow (v1 marker) → `getVersion` returns `1` → runs basic `fraudCheck` ✅
- New workflow (v2 marker) → `getVersion` returns `2` → runs advanced `fraudCheck` ✅

**Validate:**
- Workflow status changes to **Completed**

---

## Demo B — Strategy 2: Worker Deployments (Pinned)

```bash
./demo_strategy2.sh
```

`demo_strategy2.sh` does:
1. Builds a **v1 JAR** from the `main` branch (no `fraudCheck`)
2. Builds a **v2 JAR** from the `solution/worker-versioning` branch (`fraudCheck` added, no `getVersion`)
3. Registers build ID `v1` with Temporal
4. Starts the v1 worker (port 9090) — old workflows will be pinned here
5. Starts a payment workflow → pinned to v1
6. Registers build ID `v2` as the new default
7. Starts the v2 worker (port 9091)
8. Starts a new payment workflow → goes to v2
9. Signals both workflows

**Key point:** the v1 workflow never sees `fraudCheck` — it stays on the v1 worker.
No `Workflow.getVersion()` needed. Both workflows complete successfully.

**Validate in Temporal UI:**
- `payment:10` — ran on v1, no `fraudCheck` activity, COMPLETED ✅
- `payment:11` — ran on v2, `fraudCheck` ran first, COMPLETED ✅
- No `WorkflowTaskFailed` events in either workflow

---

## Workflow overview (baseline)

```
POST /payments
      │
      ▼
┌─────────────────────────────────────────────┐
│  PaymentWorkflow                            │
│                                             │
│  reserveFunds()    ← fire & forget          │
│  await signal      ← 60 min timeout         │
│  (onReservationResult)                      │
│                                             │
│  transfer()        ← sync, retries on 5XX  │
│                                             │
│  publishCompleted()                         │
│         overall timeout: 10 min            │
└─────────────────────────────────────────────┘
```

### REST endpoints

| Method | Path | Description |
|---|---|---|
| `POST` | `/payments` | Start a payment workflow |
| `POST` | `/payments/{id}/reservation-result` | Send the reservation signal |

### Wiremock (bank API stubs)

| File | Endpoint | Used by |
|---|---|---|
| `fraud-check-success.json` | `GET /api/payment/fraud-check/{id}` | `fraudCheck` activity |
| `reserve-success.json` | `POST /api/payment/reserve/{id}` | `reserveFunds` activity |
| `sepa-success.json` | `GET /api/payment/sepa/1` | `transfer` activity |
| `released.json` | `GET /api/payment/released` | `publishCompleted` activity |

---

## Project structure

```
├── demo_1.sh                        # Demo A step 1: baseline → breaking change
├── demo_2.sh                        # Demo A step 2: getVersion fix
├── demo_strategy2.sh                # Demo B: worker deployments (pinned)
├── success_payment.sh               # Quick happy-path curl
├── docker-compose.yml               # Temporal + Postgres + Wiremock
├── VERSIONING.md                    # All Temporal versioning strategies explained
├── wiremock/mappings/               # Stubbed bank API responses
└── src/main/kotlin/.../
    ├── api/PaymentResource.kt       # REST endpoints
    ├── client/PaymentApiClient.kt   # REST client (bank API)
    ├── model/                       # PaymentRequest, PaymentResult, etc.
    └── workflow/
        ├── PaymentWorkflow.kt       # @WorkflowInterface
        ├── PaymentWorkflowImpl.kt   # Workflow orchestration
        ├── PaymentActivities.kt     # @ActivityInterface
        ├── PaymentActivitiesImpl.kt # Activity implementations
        ├── ActivityStubFactory.kt   # Activity stub configuration
        └── WorkflowConstants.kt     # Task queue name, workflow ID prefix
```
