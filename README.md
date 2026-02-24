# Temporal Workflow Versioning — Live Demo

This project demonstrates how **ongoing code changes break running Temporal workflows**
and how to fix them safely — all without downtime.

The demo is built around a realistic payment workflow. It shows the problem (a breaking change)
and two different strategies to fix it, each on its own branch.

For a deep-dive on all Temporal versioning strategies, see [VERSIONING.md](./VERSIONING.md).

---

## Repository structure

```
(tag: baseline)  initial commit: the WF is working
      │
(tag: breaking, main)  added braking change   ← fraudCheck inserted, NO fix
      │
      ├── version_sdk_fix      fix: Workflow.getVersion() patch
      │
      └── worker_version_fix   fix: worker deployments (pinned versioning)
```

| State | What the code does | Effect on running workflows |
|---|---|---|
| `baseline` | `reserveFunds → transfer → publishCompleted` | ✅ Works |
| `breaking` | `fraudCheck` inserted before `reserveFunds`, no fix | 💥 `NonDeterministicException` |
| `version_sdk_fix` | `Workflow.getVersion()` guards `fraudCheck` | ✅ Old WFs replay safely, new WFs run `fraudCheck` |
| `worker_version_fix` | Old worker (v1) stays up, new worker (v2) takes new WFs | ✅ No code branching needed |

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
./demo_1.sh
```

What it does:

1. Checks out `baseline` tag — working WF, no `fraudCheck`
2. Starts the Quarkus worker (logs → `/tmp/quarkus-demo.log`)
3. Starts payment workflow via REST — parks at the reservation signal (60-min wait)
4. Stops the worker
5. Checks out `breaking` tag — `fraudCheck` added before `reserveFunds`, no fix
6. Restarts the worker
7. Sends the reservation signal

**What to observe in Temporal UI (`http://localhost:8080`):**

After step 6, within seconds:
```
WorkflowTaskFailed — NonDeterministicException:
  Command COMMAND_TYPE_SCHEDULE_ACTIVITY_TASK doesn't match
  expected: 'FraudCheck'  /  actual: 'ReserveFunds'
```

After step 7, the signal is queued but the workflow stays stuck —
every task attempt fails on replay.

**Validate:**
- Workflow status: **Running** (not Completed)
- `WorkflowTaskFailed` visible in event history
- `tail -f /tmp/quarkus-demo.log` shows repeating `NonDeterministicException`

---

### Step 2 — Apply the getVersion fix

```bash
./demo_2.sh
```

What it does:

1. Stops the broken worker
2. Checks out `version_sdk_fix` branch
3. Restarts the worker
4. Sends the reservation signal again

**How the fix works:**

```kotlin
val version = Workflow.getVersion("addFraudCheck", Workflow.DEFAULT_VERSION, 1)
if (version != Workflow.DEFAULT_VERSION) {
    activities.fraudCheck(paymentId)   // new workflows only
}
activities.reserveFunds(paymentId)     // always runs
```

- Old workflow (no marker in history) → `getVersion` returns `DEFAULT_VERSION` → skips `fraudCheck` → replay matches ✅
- New workflow → `getVersion` records marker with version `1` → `fraudCheck` runs ✅

**Validate:**
- Workflow status changes to **Completed**
- Expected event history:

```
WorkflowExecutionStarted
WorkflowTaskCompleted       ← baseline: scheduled reserveFunds + timer
ActivityTaskScheduled       ← reserveFunds
ActivityTaskCompleted
WorkflowTaskFailed          ← breaking: NonDeterministicException
WorkflowExecutionSignaled   ← signal queued (ignored while stuck)
WorkflowTaskFailed          ← breaking: retry also failed
WorkflowExecutionSignaled   ← signal from demo_2.sh
WorkflowTaskCompleted       ← version_sdk_fix: getVersion skips fraudCheck, replay OK
...
WorkflowExecutionCompleted  ← COMPLETED ✅
```

---

## Demo B — Strategy 2: Worker Deployments (Pinned)

```bash
./demo_strategy2.sh
```

What it does:

1. Builds a **v1 JAR** from the `baseline` tag (no `fraudCheck`)
2. Builds a **v2 JAR** from the `worker_version_fix` branch (`fraudCheck` added, no `getVersion`)
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
