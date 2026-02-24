# Temporal Workflow Versioning Strategies

Temporal replays workflow history on every task. Your code must produce the **exact same sequence of commands** (activities, timers, child workflows) as what is recorded in history. Any mismatch causes a non-determinism error and breaks running workflows.

---

## What Breaks Running Workflows

| Change | Breaks? |
|---|---|
| Insert a new activity/timer **anywhere** before where running WFs currently are | **Yes** |
| Remove an existing activity or timer | **Yes** |
| Reorder activities or timers | **Yes** |
| Add/remove `Workflow.sleep()` | **Yes** |
| Change `Workflow.sleep()` duration (non-zero ↔ non-zero) | No |
| Change `Workflow.sleep()` duration to/from `0` | **Yes** |
| Change workflow execution timeout | No |
| Change activity parameters or timeouts | No |
| Change non-command business logic | No |

---

## Strategy 1: `Workflow.getVersion()` Patching

Insert versioned branch points directly in workflow code. On first execution past the patch, Temporal records a Marker in history. On replay, it reads that marker and takes the same branch — deterministic across both old and new executions.

**When to use:** targeted fixes on existing deployments; no infra changes possible.

**Pros:** no infra changes, surgical, works with any SDK version.
**Cons:** branching logic accumulates in code; must clean up after all old executions complete.

### Lifecycle

**Phase 1 — Introduce patch** (deploy with both code paths):
```kotlin
val version = Workflow.getVersion("addFraudCheck", Workflow.DEFAULT_VERSION, 1)
if (version == Workflow.DEFAULT_VERSION) {
    // old path — executions that started before this patch
    activities.chargeCard()
} else {
    // new path — executions that started after this patch
    activities.checkFraud()
    activities.chargeCard()
}
```

**Phase 2 — Coexist:** both old and new executions run. No code changes needed.

**Phase 3 — Cleanup** (after ALL pre-patch executions complete + retention period expires):
```kotlin
// Keep the getVersion call to guard stale histories
Workflow.getVersion("addFraudCheck", 1, 1)
activities.checkFraud()
activities.chargeCard()
// Remove getVersion entirely only when zero replay risk remains
```

---

## Strategy 2: Worker Deployments (Server-Side Versioning)

Name your workers with a deployment version. Temporal server routes each workflow execution to the correct worker version — no code branching needed for the default (Pinned) behavior.

**When to use:** new projects or when you want clean code without patching.

### Option A: Pinned (recommended)

Old executions stay on old workers. New executions go to new workers. They never mix.

- **New** workflow starts → new workers (new code)
- **Running** workflows → stay on old workers (old code)
- **No patching needed. No breakage.**

```kotlin
WorkerOptions.newBuilder()
    .setDeploymentOptions(
        WorkerDeploymentOptions.newBuilder()
            .setVersion(WorkerDeploymentVersion("my-service", "2.0"))
            .setUseVersioning(true)
            .setDefaultVersioningBehavior(VersioningBehavior.PINNED)
            .build()
    )
    .build()
```

You must keep old workers running until all executions pinned to them complete.

**Pros:** zero patching, clean code, explicit lifecycle, supports canary/blue-green rollout.
**Cons:** must run multiple worker versions simultaneously; requires SDK v1.29.0+.

### Option B: Auto-Upgrade

Running workflows migrate to new workers on their next task (by design — you opt into this).

- Old workers needed only briefly during migration
- Server manages routing automatically
- **Still requires `getVersion()` patching** — new code must replay old history

Use when you want all workflows on the latest version ASAP and are willing to patch.
Adds operational benefits over Strategy 1 (canary rollout, easy rollback) but the patching effort is the same.

| | Strategy 1 (patch only) | Strategy 2 Auto-Upgrade |
|---|---|---|
| Old workers needed? | No | Briefly |
| Server routes tasks? | No | Yes |
| Canary / gradual rollout? | No | Yes |
| Rollback? | Hard | Easy (switch Current version) |
| Patching required? | Yes | Yes |

---

## Strategy 3: New Workflow Type per Version

Create a new `@WorkflowInterface` with a different name. Old executions continue on the old type uninterrupted. All new starts use the new type. Both registered on the same worker.

**When to use:** one-time major redesigns where the workflow contract itself changes. Not a general strategy.

```kotlin
// Original
@WorkflowInterface
interface OrderWorkflow {
    @WorkflowMethod
    fun process(order: Order): OrderResult
}

// New version — different type name
@WorkflowInterface
interface OrderWorkflowV2 {
    @WorkflowMethod
    fun process(order: Order): OrderResult
}

// Register both on the worker
worker.registerWorkflowImplementationTypes(
    OrderWorkflowImpl::class.java,
    OrderWorkflowV2Impl::class.java
)
```

All callers (clients, schedules) must be updated to start `OrderWorkflowV2`.

**Pros:** no non-determinism risk, clean separation of old and new code.
**Cons:** full code duplication; all callers must be updated; becomes unmaintainable with many versions.

---

## Safety Net: Replay Testing

Before deploying any change, validate with `WorkflowReplayer`. Download event histories from production and replay them through the new code. Integrate into CI.

```kotlin
val file = File("workflow_history.json")
WorkflowReplayer.replayWorkflowExecution(file, OrderWorkflowImpl::class.java)
```

---

## Live Example: Walking Through the Commits

This repository contains a working demonstration of Strategy 1 across 3 commits.
Use the commands below to switch between each state and observe the behaviour.

### Prerequisites

```bash
docker-compose up -d      # Temporal + Postgres + Wiremock
./gradlew quarkusDev      # start the worker (keep running in a separate terminal)
```

---

### Commit 1 — Baseline: working payment workflow

```bash
git checkout b5c10b2
```

The workflow has 3 activities in sequence: `reserveFunds → transfer → publishCompleted`.
Start a payment and send the reservation signal — it completes successfully.

```bash
./success_payment.sh
```

Watch it complete in the Temporal UI at **http://localhost:8088**.

---

### Commit 2 — Breaking change: `fraudCheck` inserted before `reserveFunds`

```bash
git checkout 07ac58e
```

Restart the worker. Now start a **new long-running workflow** (20-min reservation timer):

```bash
curl -s -X POST http://localhost:9090/payments \
  -H "Content-Type: application/json" \
  -d '{"paymentId":"1","amount":100,"currency":"EUR","debtorAccount":"LT001","creditorAccount":"LT002"}' | jq .
```

Leave this workflow **running and waiting** for the reservation signal. Now restart the worker again with commit 2 code still loaded — or simply observe the logs. The running workflow will immediately produce:

```
NonDeterministicException: Command COMMAND_TYPE_SCHEDULE_ACTIVITY_TASK
  doesn't match event EVENT_TYPE_ACTIVITY_TASK_SCHEDULED
  expected: 'FraudCheck'
  actual:   'ReserveFunds'
```

The workflow is **stuck**. New workflows start fine (they run `fraudCheck` then `reserveFunds`),
but the old running one cannot resume.

---

### Commit 3 — Fix: `Workflow.getVersion()` patch

```bash
git checkout 52a7e69
```

Restart the worker. The stuck workflow unblocks immediately:

- `getVersion("addFraudCheck", DEFAULT_VERSION, 1)` reads `DEFAULT_VERSION` from the marker in history
- The old execution **skips** `fraudCheck` and continues from `reserveFunds`
- Send the reservation signal to complete it:

```bash
curl -s -X POST http://localhost:9090/payments/1/reservation-result \
  -H "Content-Type: application/json" \
  -d '{"success": true}' | jq .
```

New workflows started after this commit will run `fraudCheck` (version = 1).
Old workflows that were running will skip it (version = `DEFAULT_VERSION`).
**Both coexist safely on the same worker.**

---

### Restore to latest

```bash
git checkout main
```

---

## Decision Guide

| Scenario | Strategy |
|---|---|
| Small targeted fix, existing deployment | Strategy 1 — `getVersion()` patching |
| New project, clean code, no patching | Strategy 2 — Pinned |
| Want all WFs on latest ASAP + canary rollout | Strategy 2 — Auto-Upgrade (+ patching) |
| One-time complete redesign | Strategy 3 — New workflow type |
