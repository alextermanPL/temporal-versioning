# Temporal Workflow Versioning — Live Demo

This project demonstrates how **ongoing code changes break running Temporal workflows**
and how to fix them safely using `Workflow.getVersion()` — all without downtime.

The demo is built around a realistic payment workflow and walks through 3 git commits:
a working baseline, a breaking change, and the correct fix.

For a deeper explanation of all Temporal versioning strategies, see [VERSIONING.md](./VERSIONING.md).

---

## The Idea

Temporal workflows are **replayed from history** on every resume. The code must produce
the exact same sequence of commands (activities, timers) as what is recorded.
Inserting a new activity in the middle breaks that sequence for any workflow already running.

This demo proves it live:

| Commit | What changes | Effect on running workflows |
|---|---|---|
| `b5c10b2` Baseline | `reserveFunds → transfer → publish` | ✅ Works |
| `07ac58e` Breaking change | `fraudCheck` inserted **before** `reserveFunds` | 💥 `NonDeterministicException` |
| `52a7e69` Version fix | `Workflow.getVersion()` wraps `fraudCheck` | ✅ Old WFs resume, new WFs run `fraudCheck` |

---

## Prerequisites

- Java 21
- Docker + Docker Compose
- `jq` (`brew install jq`)

---

## Step 1 — Start infrastructure

```bash
docker-compose up -d
```

This starts:
- **Temporal server** on `localhost:7233`
- **Temporal UI** on `http://localhost:8088`
- **PostgreSQL** (Temporal persistence)
- **Wiremock** on `localhost:8089` (mocks the payment bank API)

**Validate:**
- Open `http://localhost:8088` — Temporal UI loads
- `curl -s http://localhost:8089/api/payment/sepa/1 | jq .` returns `{"status":"continue"}`

---

## Step 2 — Run the full demo automatically

The demo is split into two scripts that match the 3 commits.

### demo_1.sh — Baseline → Breaking change

```bash
./demo_1.sh
```

What it does, step by step:

1. Checks out **commit 1** (baseline — no `fraudCheck`)
2. Starts the Quarkus worker (`./gradlew quarkusDev`, logs → `/tmp/quarkus-demo.log`)
3. Starts a payment workflow via REST — the workflow parks at the reservation signal (20-min wait)
4. Stops the worker
5. Checks out **commit 2** (breaking change — `fraudCheck` added before `reserveFunds`, no `getVersion`)
6. Restarts the worker
7. Sends the reservation signal

**What to observe in the Temporal UI (`http://localhost:8088`):**

After step 6 (worker restarts with commit 2), open the workflow and watch the event history.
Within seconds you will see `WorkflowTaskFailed` with:

```
NonDeterministicException:
  Command COMMAND_TYPE_SCHEDULE_ACTIVITY_TASK doesn't match
  expected: 'FraudCheck'
  actual:   'ReserveFunds'
```

After step 7 (signal sent), the workflow remains stuck — the signal is queued but cannot
be processed because every workflow task attempt fails on replay.

You may see **two** `WorkflowTaskFailed` events. This is expected: Temporal automatically
retries a failed workflow task after ~10 seconds. If the broken worker is still up during
the retry, it fails a second time.

**Validate:**
- Workflow status in the UI shows **Running** (not Completed)
- `WorkflowTaskFailed` events visible in the event history
- Logs show `NonDeterministicException` repeating: `tail -f /tmp/quarkus-demo.log`

---

### demo_2.sh — Version fix: unblocking the stuck workflow

```bash
./demo_2.sh
```

What it does, step by step:

1. Stops the broken worker
2. Checks out **commit 3** (version fix — `Workflow.getVersion()` wraps `fraudCheck`)
3. Restarts the worker
4. Sends the reservation signal again

**How the fix works:**

```kotlin
val version = Workflow.getVersion("addFraudCheck", Workflow.DEFAULT_VERSION, 1)
if (version != Workflow.DEFAULT_VERSION) {
    activities.fraudCheck(request.paymentId)   // only for NEW workflows
}
activities.reserveFunds(request.paymentId)     // always runs
```

When the fixed worker replays the stuck workflow's history:
- No `addFraudCheck` marker exists in history → `getVersion` returns `DEFAULT_VERSION`
- The `if` branch is skipped → `reserveFunds` is command #1, matching history ✅
- Replay succeeds, signal is processed, workflow resumes

When a **new** workflow starts on the fixed worker:
- `getVersion` records a marker with version `1` → `fraudCheck` runs ✅

**Validate:**
- Workflow status in the UI changes to **Completed**
- Final result in event history: `{"paymentId":"1","status":"COMPLETED"}`
- The event history will look like this:

```
WorkflowExecutionStarted
WorkflowTaskCompleted       ← commit 1: scheduled reserveFunds + timer
TimerStarted                ← 10-min overall timeout
ActivityTaskScheduled       ← reserveFunds
ActivityTaskCompleted       ← reserveFunds done
WorkflowTaskFailed          ← commit 2: NonDeterministicException
WorkflowExecutionSignaled   ← signal queued (ignored while stuck)
WorkflowTaskFailed          ← commit 2: retry also failed
WorkflowExecutionSignaled   ← signal from demo_2.sh
WorkflowTaskCompleted       ← commit 3: getVersion fix, replay OK
...
WorkflowExecutionCompleted  ← COMPLETED ✅
```

At the end, `demo_2.sh` restores the repo to `main`.

---

## Step 3 — Run a clean successful payment (optional)

To verify the fixed worker handles new workflows correctly (with `fraudCheck` running):

```bash
./success_payment.sh
```

This starts a new payment (`paymentId=1`) and immediately signals it.
The new workflow will execute `fraudCheck` first (version = 1), then the full payment flow.

**Validate:**
- A second workflow appears in the UI and completes immediately
- Event history shows `ActivityTaskScheduled` for `FraudCheck` before `ReserveFunds`

---

## Payment workflow overview

```
REST POST /payments
        │
        ▼
┌───────────────────────────────────────────────┐
│  PaymentWorkflow                              │
│                                               │
│  [getVersion guard]                           │
│  fraudCheck()        ← new WFs only (v=1)    │
│                                               │
│  reserveFunds()      ← fire & forget          │
│  await signal        ← timer1: 20 min         │
│  (onReservationResult)                        │
│                                               │
│  transfer()          ← sync, retries on 5XX  │
│                                               │
│  publishCompleted()  ← or publishRejected()  │
│         on failure / overall timeout (10 min)│
└───────────────────────────────────────────────┘
```

### REST endpoints

| Method | Path | Description |
|---|---|---|
| `POST` | `/payments` | Start a payment workflow |
| `POST` | `/payments/{id}/reservation-result` | Signal the reservation outcome |

### Wiremock scenarios (bank API)

| `paymentId` | Transfer result | Scenario |
|---|---|---|
| `1` | 200 `{"status":"continue"}` | Success |
| `2` | 400 Bad Request | Client error — non-retryable, workflow fails |
| `3` | 200 with 5s delay | Slow response — tests activity timeout |

---

## Project structure

```
├── demo_1.sh                        # Automated demo: baseline → breaking change
├── demo_2.sh                        # Automated demo: version fix → unblock
├── success_payment.sh               # Quick happy-path curl
├── docker-compose.yml               # Temporal + Postgres + Wiremock
├── VERSIONING.md                    # Deep-dive: all Temporal versioning strategies
├── wiremock/mappings/               # Stubbed bank API responses
└── src/main/kotlin/.../
    ├── api/PaymentResource.kt       # REST endpoints
    ├── client/PaymentApiClient.kt   # REST client (bank API)
    ├── model/                       # PaymentRequest, PaymentResult, etc.
    └── workflow/
        ├── PaymentWorkflow.kt       # @WorkflowInterface
        ├── PaymentWorkflowImpl.kt   # Orchestration + getVersion patch
        ├── PaymentActivities.kt     # @ActivityInterface
        ├── PaymentActivitiesImpl.kt # Activity implementations
        ├── ActivityStubFactory.kt   # Activity stub configuration
        └── WorkflowConstants.kt     # Task queue, workflow ID prefix
```
