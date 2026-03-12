# PerFourceCommanderConsole — Responsive Command Execution Plan

## Purpose

This is a revised, code-accurate plan for making long-running Perforce operations more understandable, faster to recover from, and eventually non-blocking.

It keeps the original direction, but adjusts the milestones to match the **current implementation**:

- reducer-driven UDF,
- a synchronous side-effect gateway,
- a separate command log surface,
- shared-by-reference caches,
- and workflow executors that are not yet fully normalized.

The plan prioritizes **elegance, robustness, flexibility, and testability**.

---

## Problem Summary

The current TUI is still effectively blocked while a long-running `p4` command executes.

Observed symptoms:

- the busy modal renders one frame and then stops updating,
- keyboard input is not processed until the command returns,
- resize handling also pauses during I/O,
- opening the files screen can block on both:
  - the initial `p4 fstat` load,
  - follow-up content-diff enrichment (`p4 diff -sa`),
- pending changelist loading can also be expensive because enrichment currently includes opened, shelved, and unresolved counts.

The goal is not just “make it async”, but to reach a solution that is:

- correct by construction,
- reducer-authoritative,
- explicit about stale results,
- safe for cancellation,
- and straightforward to test.

---

## Goals

1. Make slow operations understandable instead of feeling frozen.
2. Reduce synchronous wait time on common workflows.
3. Give users control during long operations.
4. Reach a long-term model where the UI remains responsive while read-heavy commands run.
5. Support true cancellation with clear user-facing outcomes.
6. Keep the reducer authoritative even after background execution is introduced.

---

## Non-Goals

This plan does **not** require, at least initially:

- rewriting the reducer architecture,
- making every command parallel immediately,
- streaming raw `p4` output live into the UI,
- introducing a full job scheduler or persistence layer,
- allowing unrestricted browsing/navigation while foreground commands are active.

Those can come later if the background model proves stable.

---

## Current Architecture Baseline

## Main loop

The main loop is still fundamentally:

```text
State → Render → Poll Input/Resize → Map Action → Reducer → Consume PendingRequest → State'
```

Important detail:

- during synchronous I/O, the loop is not alive,
- so neither input nor periodic UI updates can happen,
- and future async support will require an explicit **idle tick** that can drain completions even when no key is pressed.

## Side-effect gateway

`Invoke-BrowserSideEffect` currently:

1. dispatches `CommandStart`,
2. renders the busy modal,
3. registers a `p4` observer,
4. runs the work item synchronously,
5. logs observer events through `LogCommandExecution`,
6. dispatches `CommandFinish`.

This remains the core synchronous orchestration path.

### Important correction

Not every user-visible command currently goes through one uniform wrapper:

- startup `Get-P4Info` happens outside it,
- `MoveMarkedFiles` does not use the same workflow command helper as other workflows.

That inconsistency should be fixed before async behavior is layered on.

## Reducer and command surfaces

The code currently has **two command-history surfaces**:

1. **Busy/history modal**
   - backed by `Runtime.ModalPrompt.History`
   - populated by `CommandFinish`

2. **Command Log view**
   - backed by `Runtime.CommandLog`
   - populated by `LogCommandExecution`

This distinction matters. Timeout classes, slow-command buckets, and cancel/timeout outcomes must be designed to work for both surfaces.

## Caches and state copying

Current cache behavior:

- `DescribeCache`, `FileCache`, and `CommandOutputCache` are intentionally shared by reference across copied states,
- that works today because they are treated largely as append-only shared data.

This is acceptable in the synchronous model, but it becomes a hazard once async work and richer status transitions are introduced.

## File loading

For opened files, loading is currently one blocking unit:

1. `Get-P4OpenedFiles`
2. `Get-P4ModifiedDepotPaths`
3. `Set-P4FileEntriesContentModifiedState`

That is the clearest first-paint hotspot in the current UI.

## Pending changelist loading

`Get-P4ChangelistEntries` currently performs multiple enrichment steps:

1. pending changelists,
2. opened file counts,
3. shelved file counts,
4. unresolved counts,
5. and sometimes `Get-P4Info` for default changelist synthesis.

In particular, unresolved enrichment can devolve into one `p4 fstat` query per changelist.

## Workflows

Workflow progress already exists conceptually:

```text
WorkflowBegin → (WorkflowItemComplete | WorkflowItemFailed)* → WorkflowEnd
```

That gives useful checkpoint boundaries, but the command execution path is not yet fully uniform across all workflows.

---

## Constraints

### C1 — The main loop currently stops during I/O

No live timer, no input, no resize handling while a synchronous `p4` command is running.

### C2 — Only the main thread should write to `[Console]`

Background workers must not render directly.

### C3 — Thread-job runspaces are isolated

Modules must be imported explicitly, and background work should return **data**, not mutated application state.

### C4 — Shared caches are safe only under a narrow contract today

The current shared-reference cache model is manageable while writes are simple and synchronous. It becomes much more fragile if async jobs or richer cache-entry status transitions are introduced carelessly.

### C5 — `Escape` currently means dismiss, not cancel

Busy-state cancellation semantics do not exist yet and must be introduced explicitly.

### C6 — A single `PendingRequest` slot is enough for sync sequencing, but not for general async orchestration

The current one-shot signal is a good synchronous pattern, but later milestones need request identity, generation tracking, and explicit completion events.

---

## Design Rules

These rules apply to every milestone.

### Rule 1 — The reducer stays authoritative

Background workers may gather data or execute commands, but they must not own application state mutations.

### Rule 2 — No background state mutation

A worker returns typed payloads such as `FilesBaseLoaded`, `PendingChangesLoaded`, or `CommandFailed`. The reducer integrates them.

### Rule 3 — Keep live handles out of copied state

Reducer state may store:

- `RequestId`
- timestamps
- display strings
- scalar IDs
- status fields

Live job objects, queues, or process objects should stay in module-scoped registries keyed by `RequestId`.

### Rule 4 — Prefer first paint over full enrichment

Partial but clearly-labeled data is better than perfect-but-late data.

### Rule 5 — Treat stale results as normal

Once background work exists, stale results are expected, not exceptional.

### Rule 6 — Normalize access before changing data shape

If `FileCache` or other caches need richer metadata, first introduce accessors/helpers or a sibling metadata dictionary.

### Rule 7 — Use DI for orchestration

The same orchestration layer should run inline in tests and via workers in production.

### Rule 8 — Add no naked constants

Timeouts, thresholds, durations, debounce intervals, and state labels should come from shared named policy objects.

---

## Strategy Summary

Deliver the work in six milestones:

1. **Milestone 0 — Foundation**
2. **Milestone 1 — Instrumentation and static UX**
3. **Milestone 2 — Faster synchronous first paint**
4. **Milestone 3 — Busy-state control and semantics**
5. **Milestone 4 — Async read-only execution**
6. **Milestone 5 — Async mutation and true cancellation**

This keeps the rollout incremental and shippable.

---

# Milestone 0 — Foundation

## Objective

Prepare the codebase for later async work without changing the execution model yet.

This milestone is small but important: it removes architectural ambiguity that would otherwise make M4-M5 brittle.

## Scope

### 0.1 Normalize workflow command execution

Make all workflow items use one common execution helper so they all get the same:

- modal behavior,
- logging behavior,
- error capture,
- and later checkpoint/cancel semantics.

In practice, `MoveMarkedFiles` should be brought onto the same conceptual path as the other workflows.

### 0.2 Introduce a typed request envelope

Replace bare request objects like:

```powershell
@{ Kind = 'LoadFiles' }
```

with a richer envelope shape such as:

```powershell
@{
    RequestId   = 'req-17'
    Kind        = 'LoadFilesBase'
    Scope       = 'Files'
    CacheKey    = '123:Opened'
    Generation  = 4
    CommandLine = 'p4 fstat ...'
}
```

This still works in the synchronous model, but creates the identity needed later for stale-result handling.

### 0.3 Define shared command/result records

Create one shared conceptual model for command results, used by both:

- the busy/history modal,
- the command log,
- later async completion actions.

Recommended fields:

```powershell
@{
    RequestId      = 'req-17'
    CommandLine    = 'p4 ...'
    Subcommand     = 'fstat'
    Category       = 'FileQuery'
    StartedAt      = ...
    EndedAt        = ...
    DurationMs     = 1234
    DurationClass  = 'Warning'
    Outcome        = 'Completed'   # Completed | Failed | TimedOut | Cancelled
    ExitCode       = 0
    ErrorText      = ''
}
```

### 0.4 Add cache access helpers or a sibling metadata dictionary

Do **not** immediately replace `FileCache[$cacheKey] = FileEntry[]` everywhere.

Instead, do one of these first:

- add cache accessor helpers, or
- keep dynamic load/enrichment state in a separate dictionary keyed by `cacheKey`.

The second option is especially attractive because it preserves current `FileCache` assumptions while allowing richer status tracking.

### 0.5 Add an executor seam and idle-tick helper

Add DI for the execution orchestrator early, even if production still runs synchronously.

This gives the code a stable place to attach:

- fake executors,
- fake clocks,
- fake completion queues,
- future thread-job implementations.

## Suggested Files

- `PerfourceCommanderConsole.psm1`
- `tui/Reducer.psm1`
- `tui/Input.psm1`
- `tui/Render.psm1`
- `p4/P4Cli.psm1`
- optionally a new helper module such as `tui/CommandRuntime.psm1`

## Acceptance Criteria

- All workflows use a consistent execution path.
- Requests have stable identity and scope.
- Modal history and command log can share one outcome taxonomy.
- A future async executor can be swapped in without redesigning the reducer contract.

---

# Milestone 1 — Instrumentation and Static UX

## Objective

Make waits more understandable and diagnosable without changing the synchronous execution model.

## Scope

### 1.1 Add shared thresholds and timeout policy

Define named shared policy objects in `P4Cli.psm1` for:

- duration buckets,
- timeout buckets,
- command categories.

For example:

```powershell
$script:CommandThresholds = [pscustomobject]@{
    InfoMs     = 500
    WarningMs  = 2000
    CriticalMs = 5000
}

$script:P4TimeoutByCategory = @{
    Metadata  = 10000
    FileQuery = 30000
    Describe  = 15000
    Mutating  = 30000
}
```

And resolve command category from arguments via a shared helper.

### 1.2 Improve the static busy modal copy

The modal is still static in this milestone, so keep the improvement static and honest.

Suggested content:

- header/body: `[⏳] Running: p4 fstat ...`
- footer: `[ℹ] Waiting for Perforce. Timeout: 30s`

If a workflow is active, the footer can already include static step progress text.

### 1.3 Improve both command-history surfaces together

Apply the shared classification model to:

- modal history rows,
- command log rows,
- command detail pane,
- command log filters.

That includes:

- duration color classes,
- explicit `TimedOut` vs `Failed`,
- prominent subcommand display,
- status filters beyond just `OK` and `Error`.

### 1.4 Keep timeout override behavior explicit

Allow low-level callers to override timeout explicitly, but let `Invoke-P4` resolve a category-aware default when none is supplied.

## Acceptance Criteria

- Busy modal shows clearer static text and timeout information.
- Command log and modal history use the same duration/outcome taxonomy.
- Timeouts are category-aware and centrally defined.
- Existing command flows still behave normally.

---

# Milestone 2 — Faster Synchronous First Paint

## Objective

Reduce blocking time in common workflows without introducing background execution yet.

## Scope

### 2.1 Split opened-files loading into base load and enrichment

Change the opened-files path from:

```text
Load files = fstat + diff enrichment + state update
```

to:

```text
Request A: base file load (fstat)
→ return to main loop and render
Request B: content-diff enrichment (diff -sa)
→ re-render when done
```

This is the highest-value synchronous UX improvement.

### 2.2 Introduce explicit file-load status

Track file-loading phases explicitly, for example:

```text
NotLoaded → LoadingBase → BaseReady → LoadingEnrichment → Ready
                                          └────────────→ EnrichmentFailed
```

Recommended implementation:

- keep `FileCache` as raw `FileEntry[]` for now,
- store phase/status in a separate dictionary keyed by `cacheKey`, or behind accessors.

That avoids an immediate broad cache-shape migration.

### 2.3 Render partially enriched state clearly

When content status is not yet known:

- render a pending glyph such as `…`,
- show a clear inspector/status-bar note,
- avoid pretending “clean” when the data is simply not loaded yet.

### 2.4 Make enrichment idempotent and demand-driven

If enrichment is already loading or ready, do not re-request it.

Good triggers:

- files screen opened,
- content-status column visible,
- future file filter depends on content-modified state,
- user explicitly reloads.

### 2.5 Optional future branch: progressive changelist enrichment

After the files split proves useful, the same idea can later be applied to pending changelists:

- load base changelists first,
- enrich counts progressively.

That is a good extension, but it should not distract from the files-screen hotspot first.

## Acceptance Criteria

- Opening the files screen reaches first paint without waiting for `p4 diff -sa`.
- UI distinguishes “pending enrichment” from “clean”.
- Reload and re-entry stay idempotent.
- Tests cover status transitions and partially enriched rendering.

---

# Milestone 3 — Busy-State Control and Semantics

## Objective

Improve user control within the synchronous architecture by acting at safe checkpoints.

## Scope

### 3.1 Add `RequestCancel` and deferred quit semantics

Introduce explicit state for:

- `CancelRequested`
- `QuitRequested`

While still synchronous, cancel only means:

- stop after the current safe step,
- not interrupt the currently running native process.

### 3.2 Define busy-state key precedence

When busy, recommended precedence is:

1. `Escape` cancels overlay if one is open,
2. otherwise `Escape` means `RequestCancel`,
3. `Q` means deferred quit,
4. hide/dismiss behavior applies only when not busy.

### 3.3 Poll between workflow items

Workflow executors already have item boundaries.

Between items:

- poll for key input,
- accept cancel/quit requests,
- update reducer state accordingly.

### 3.4 Split more compound synchronous work into checkpoints

The file-load split from Milestone 2 is the first case.

Additional candidates later:

- pending changelist enrichment phases,
- multi-step mutating workflows.

### 3.5 Improve modal messaging for workflow state

Examples:

- `[⏳] Working… (step 2/5)`
- `[⚠] Cancel requested — finishing current step…`
- `[⚠] Will quit after current command…`

## Acceptance Criteria

- User can request cancel between workflow steps.
- User can request quit while busy and exit cleanly afterwards.
- Modal/footer language reflects busy-state intent clearly.
- All workflows use the same busy/cancel semantics.

---

# Milestone 4 — Async Read-Only Execution

## Objective

Keep the UI responsive during long-running **read-only** operations.

Start with read-only commands only. That yields most of the user benefit with much lower correctness risk than async mutation.

## Scope

### 4.1 Introduce one foreground async lane

Start with exactly one active foreground request at a time.

That request can be:

- pending reload,
- submitted reload,
- files base load,
- files enrichment,
- describe fetch.

Do not start with multiple simultaneous foreground commands.

### 4.2 Use an executor abstraction

Production executor:

- starts a background worker (likely `Start-ThreadJob`),
- imports required modules,
- runs typed read-only work,
- publishes typed completion payloads.

Test executor:

- runs inline,
- returns deterministic completions,
- avoids thread timing flakiness.

### 4.3 Redesign the main loop to drain completions during idle

The loop must explicitly do work even when the user is not pressing keys:

```text
Render
Poll Input
Check Resize
Drain Completion Queue
Dispatch Reducer Actions
Sleep 50 ms
```

That redesign is mandatory for responsive async behavior.

### 4.4 Keep only scalar async state in reducer state

Recommended foreground state shape:

```powershell
Runtime.ActiveCommand = @{
    RequestId       = 'req-17'
    Kind            = 'LoadFilesBase'
    Scope           = 'Files'
    CacheKey        = '123:Opened'
    Generation      = 4
    CommandLine     = 'p4 fstat ...'
    StartedAt       = ...
    Status          = 'Running'   # Running | Cancelling
    CancelRequested = $false
}
```

Actual job/process handles live outside reducer state.

### 4.5 Use typed completion actions, not background state mutation

Examples:

- `PendingChangesLoaded`
- `FilesBaseLoaded`
- `FilesEnrichmentCompleted`
- `DescribeLoaded`
- `CommandFailed`

The worker returns payload data only. The reducer updates state.

### 4.6 Add generation-based stale-result protection

Use request identity plus scope/generation to discard results that are no longer relevant.

Suggested generations:

- pending-view generation,
- submitted-view generation,
- per-file-cache-key generation.

### 4.7 Enable live elapsed-time display

Once the main loop stays alive, the busy modal can show a true live timer.

### 4.8 Preserve command observation and logging

The async worker should still return structured command observation data so:

- command log remains useful,
- modal history remains coherent,
- subcommand, duration, outcome, and output preview remain available.

This can be implemented via:

- an observer capture helper inside the worker, or
- richer `Invoke-P4` hooks such as `OnProcessStarted` / `OnProcessFinished` / `OnCommandObserved`.

## Acceptance Criteria

- UI stays responsive during long-running read-only commands.
- Completions are applied without requiring a keypress.
- Live elapsed time updates in the busy modal.
- Stale results are safely ignored.
- Command logging still works.

---

# Milestone 5 — Async Mutation and True Cancellation

## Objective

Extend the async model to mutating workflows and add true cancel semantics.

This milestone should happen only after read-only async behavior is stable.

## Scope

### 5.1 Add process-aware cancellation

When a command is active:

1. user presses `Escape`,
2. reducer marks the request as cancelling,
3. runtime looks up the active process handle or PID for that request,
4. runtime kills the process tree,
5. runtime stops/cleans up the worker,
6. reducer receives `CommandCancelled`.

### 5.2 Report more than one process transition when needed

Compound operations may launch more than one native `p4` process over their lifetime.

So the runtime should not assume only one immutable `ProcessId` for the whole request.

Instead, allow worker-to-main-thread process lifecycle events such as:

- `ProcessStarted`
- `ProcessFinished`

keyed by `RequestId`.

### 5.3 Distinguish outcomes clearly

User-visible command outcomes should include at least:

- `Completed`
- `Failed`
- `TimedOut`
- `Cancelled`

These should drive:

- modal tags,
- command log filters,
- detail pane text,
- future analytics/telemetry.

### 5.4 Expand async support to mutating workflows carefully

Once cancellation and completion semantics are proven for read-only requests, extend them to:

- delete change,
- delete shelved files,
- shelve files,
- move/reopen workflows.

Keep workflow progress explicit and reducer-driven.

### 5.5 Allow limited history interaction while a command runs

Once the main loop is fully alive during async work, limited safe interactions can remain enabled:

- command log view,
- command output preview,
- scrolling history,
- viewing active command details.

General navigation should remain blocked until explicit conflict rules are designed.

## Acceptance Criteria

- User can truly cancel a running command.
- Cancelled, timed out, and failed outcomes are distinct everywhere.
- Async mutation follows the same lifecycle semantics as async reads.
- Partial progress and workflow outcome remain understandable.

---

## Cross-Cutting Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Shared-reference caches hide mutable state bugs | stale or incorrect UI updates | keep async handles out of state; use accessors or sibling metadata dictionaries |
| Completion queue is not drained while idle | async UI appears frozen | redesign main loop around an idle tick |
| Worker scriptblocks become stateful and hard to reason about | brittle async logic | make workers return typed data, never mutated state |
| `Stop-Job` does not kill native child process reliably | cancel appears broken | process-tree kill first, job cleanup second |
| Command outcomes differ between modal and command log | inconsistent UX | shared command record schema and shared classification helpers |
| Workflow implementations diverge | hard-to-test behavior | normalize workflow execution before async rollout |
| Thread-job import overhead becomes visible | latency on short commands | accept initially; consider runspace pooling later if measured |

---

## Testing Strategy

## Guiding Principles

- Run Pester in a fresh `pwsh -NoProfile` process.
- Use DI so orchestration tests do not depend on live Perforce.
- Test behavior and contracts rather than raw constant values.
- Normalize 0..N results with `@(...)` at call boundaries.

## Unit Tests

### Milestone 0–1

- workflow execution is normalized,
- request envelopes carry identity and scope,
- shared command outcome classification,
- timeout resolution by command category,
- busy modal copy and command-history rendering,
- command log filters support richer outcomes.

### Milestone 2

- file-load state transitions,
- files first paint before enrichment,
- enrichment idempotence,
- pending indicator rendering,
- reload semantics with partial data.

### Milestone 3

- busy-state key precedence,
- cancel request between workflow items,
- deferred quit,
- workflow progress footer messaging.

### Milestone 4

- idle loop drains completions without keypress,
- active command lifecycle,
- stale-result dropping via generation/scope,
- live elapsed-time formatting,
- command observation survives async execution.

### Milestone 5

- cancel lifecycle,
- timeout vs cancel vs failure distinctions,
- process lifecycle event handling,
- async mutation workflow progress,
- race: cancel vs completion,
- race: timeout vs completion.

## Integration Tests

- open files screen: base load first, enrichment later,
- pending reload while idle receives completion,
- stale file-load completion ignored after navigation or reload,
- deferred quit during busy operation,
- async foreground read completes and updates UI,
- cancellation reports the correct outcome.

## Real Async Smoke Tests

Keep these few and focused:

- completion arrives with no keypress,
- stale completion is discarded,
- cancel kills the active process,
- timeout cleanup path works.

Most other async behavior should remain covered by deterministic fake-executor tests.

---

## Recommended Delivery Order

### Release A

- Milestone 0
- Milestone 1
- opened-files split from Milestone 2

### Release B

- remaining Milestone 2 work
- Milestone 3

### Release C

- Milestone 4 for read-only requests

### Release D

- Milestone 5

---

## Recommended First Implementation Slice

If implementation starts immediately, the best first slice is:

1. normalize workflow execution,
2. introduce shared timeout and threshold policy,
3. improve static busy modal text,
4. create shared command outcome classification,
5. split opened-files load into base load + enrichment,
6. add explicit file-load status without forcing a broad `FileCache` shape change.

That slice produces user-visible value quickly and also reduces later architectural risk.

---

## Future Extensions

Once the core plan is stable, the following are good next steps:

- progressive enrichment for pending changelists,
- low-priority background enrichment lane,
- speculative read-only prefetch,
- runspace pooling to amortize module-import cost,
- adaptive timeout policy based on measured command durations,
- an internal debug surface for active requests, generations, and dropped stale results.

---

## Final Guidance

The most important refinement in this revised plan is simple:

> Build a small architectural foundation first, then add async read-only execution, and only then extend to true cancel and async mutation.

That ordering fits the current codebase, preserves the reducer contract, and gives the project the best chance of ending up with a solution that is elegant, robust, and flexible.
