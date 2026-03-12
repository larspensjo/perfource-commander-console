# PerFourceCommanderConsole — Responsive Command Execution Plan

## Purpose

This plan makes long-running Perforce operations more understandable, faster to
recover from, and eventually non-blocking.

It is written against the **current implementation** (2026-03-12):

- reducer-driven UDF with `Invoke-BrowserReducer`,
- a synchronous side-effect gateway (`Invoke-BrowserSideEffect`),
- two command-history surfaces (modal history + command log),
- shared-by-reference append-only caches,
- a workflow registry (`Register-WorkflowKind`) with four built-in executors,
- and a single-shot `PendingRequest` slot for side-effect signaling.

The plan prioritizes **elegance, robustness, flexibility, and testability**.

---

## Problem Summary

The TUI is blocked while any `p4` command executes.

Observed symptoms:

- The busy modal renders one frame and then stops updating.
- Keyboard input is not processed until the command returns.
- Resize handling pauses during I/O.
- Opening the files screen blocks on both the initial `p4 fstat` load and
  follow-up content-diff enrichment (`p4 diff -sa`).
- Pending changelist loading is expensive because enrichment includes opened,
  shelved, and unresolved counts — the latter can degrade to one `p4 fstat`
  query per changelist.

The goal is to reach a solution that is:

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
4. Reach a long-term model where the UI remains responsive while read-heavy
   commands run.
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

### Main Loop

```text
State → Render → Poll Input/Resize → Map Action → Reducer → Consume PendingRequest → State'
```

During synchronous I/O the loop is not alive — neither input nor periodic UI
updates can happen. Future async support requires an explicit **idle tick** that
drains completions even when no key is pressed.

### Side-Effect Gateway

`Invoke-BrowserSideEffect` currently:

1. dispatches `CommandStart`,
2. renders the busy modal (one frame),
3. registers a `p4` observer,
4. runs the work item synchronously,
5. logs observer events through `LogCommandExecution`,
6. dispatches `CommandFinish`.

### Workflow Registry and Execution

All four built-in workflows (`DeleteMarked`, `MoveMarkedFiles`, `ShelveFiles`,
`DeleteShelvedFiles`) are registered via `Register-WorkflowKind` and follow
the same lifecycle:

```text
WorkflowBegin → (WorkflowItemComplete | WorkflowItemFailed)* → WorkflowEnd
```

Three of the four (`DeleteMarked`, `ShelveFiles`, `DeleteShelvedFiles`) route
individual items through `Invoke-BrowserWorkflowCommand`, which delegates to
`Invoke-BrowserSideEffect` — so each item gets observer logging and modal
history entries.

**Remaining gap:** `MoveMarkedFiles` calls `Invoke-P4ReopenFiles` directly in a
try/catch, bypassing the side-effect gateway for individual items. Startup
`Get-P4Info` also runs outside the gateway.

### Two Command-History Surfaces

1. **Busy/history modal** — backed by `Runtime.ModalPrompt.History`, populated by
   `CommandFinish`.
2. **Command Log view** — backed by `Runtime.CommandLog`, populated by
   `LogCommandExecution`.

Timeout/duration classes, outcomes, and cancel semantics must work for both.

### Caches and State Copying

- `DescribeCache`, `FileCache`, and `CommandOutputCache` are `IDictionary`
  instances shared by reference across copied states.
- `Copy-StateObject` deep-copies `PSCustomObject` trees but passes dictionaries
  by reference (append-only contract) and clones `HashSet<string>` instances.
- This is safe in the synchronous model because only the main thread writes.
  **Under async execution, shared dictionaries become a hazard** — the plan
  addresses this in Milestone 4.

### File Loading

For opened files, loading is currently one blocking unit inside
`Invoke-BrowserFilesLoad`:

1. `Get-P4OpenedFiles` — base `fstat` query
2. `Get-P4ModifiedDepotPaths` — `diff -sa` query
3. `Set-P4FileEntriesContentModifiedState` — enrichment merge

This is the clearest first-paint hotspot.

### Pending Changelist Loading

`Get-P4ChangelistEntries` performs:

1. `Get-P4PendingChangelists` (includes `Get-P4Info` for user/client scoping)
2. `Get-P4OpenedFileCounts`
3. `Get-P4ShelvedFileCounts` (batched in groups of 50)
4. `Get-P4UnresolvedFileCounts` (can degrade to one `p4 fstat` per CL)
5. Default changelist synthesis if needed.

### Observer Pattern

`Register-P4Observer` installs a single module-scoped `$script:P4ExecutionObserver`
scriptblock. This is session-global, not per-request. **This must be replaced
before async execution** because overlapping `Invoke-P4` calls from different
workers would clobber each other's observer.

---

## Constraints

### C1 — The main loop stops during I/O

No live timer, no input, no resize handling while a synchronous `p4` command
is active.

### C2 — Only the main thread should write to `[Console]`

Background workers must not render directly.

### C3 — Thread-job runspaces are isolated

Modules must be imported explicitly. Background work must return **data**,
not mutated application state.

### C4 — Shared caches are safe only under single-thread access

PowerShell hashtables are not thread-safe. Under async execution, all cache
writes **must** happen on the main thread (via completion-queue drain), never
from a background worker.

### C5 — `Escape` currently means dismiss, not cancel

The `HideCommandModal` action already handles overlay precedence (dismiss
overlay first, then close modal). Cancel semantics must be layered on
explicitly.

### C6 — Single `PendingRequest` slot

The current one-shot signal is sufficient for synchronous sequencing. Async
orchestration needs request identity, generation tracking, and explicit
conflict resolution (see Milestone 4).

### C7 — `$script:P4ExecutionObserver` is session-global

Only one observer can be registered. Async workers that call `Invoke-P4`
independently would clobber the observer. This must be replaced with a
per-invocation callback (see Milestone 0).

---

## Design Rules

These rules apply to every milestone.

### Rule 1 — The reducer stays authoritative

Background workers may gather data or execute commands, but they must not own
application state mutations.

### Rule 2 — No background state mutation

A worker returns typed payloads (`FilesBaseLoaded`, `PendingChangesLoaded`,
`CommandFailed`). The reducer integrates them. Cache writes happen on the
main thread only.

### Rule 3 — Keep live handles out of copied state

Reducer state may store `RequestId`, timestamps, display strings, scalar IDs,
and status fields. Live job objects, queues, or process objects stay in
module-scoped registries keyed by `RequestId`.

### Rule 4 — Prefer first paint over full enrichment

Partial but clearly-labeled data is better than perfect-but-late data.

### Rule 5 — Treat stale results as normal

Once background work exists, stale results are expected, not exceptional.
Generation-based filtering is the primary defense.

### Rule 6 — Use sibling metadata dictionaries, not cache-shape changes

To track richer lifecycle metadata (load phase, enrichment status), add a
separate dictionary keyed by `cacheKey` instead of changing `FileCache` value
shape. This preserves current `FileCache` assumptions and avoids a broad
migration.

### Rule 7 — Use DI for orchestration

The same orchestration layer should run inline in tests and via workers in
production.

### Rule 8 — No naked constants

Timeouts, thresholds, durations, debounce intervals, and state labels come
from shared named policy objects.

### Rule 9 — Per-invocation observation, not session-global

Replace the single `$script:P4ExecutionObserver` slot with a per-invocation
callback parameter on `Invoke-P4` (or on the side-effect wrapper) so that
concurrent async callers do not interfere.

---

## Strategy Summary

1. **Milestone 0 — Foundation**
2. **Milestone 1 — Instrumentation and Static UX**
3. **Milestone 2 — Faster Synchronous First Paint**
4. **Milestone 3 — Busy-State Control and Semantics**
5. **Milestone 4 — Async Read-Only Execution**
6. **Milestone 5 — Async Mutation and True Cancellation**

---

# Milestone 0 — Foundation

## Objective

Prepare the codebase for later async work without changing the execution model.

## Scope

### 0.1 Normalize remaining workflow execution gaps

**Current state:** Three of four workflows route individual items through
`Invoke-BrowserWorkflowCommand`. `MoveMarkedFiles` calls `Invoke-P4ReopenFiles`
directly, bypassing observer logging and modal history for per-item commands.
Startup `Get-P4Info` runs outside the side-effect gateway.

**Work required:**

- Make `MoveMarkedFiles` use `Invoke-BrowserWorkflowCommand` for each
  `Invoke-P4ReopenFiles` call, matching the other three workflows.
- Wrap startup `Get-P4Info` in `Invoke-BrowserSideEffect` so it appears in
  the command log.

### 0.2 Introduce observer-per-invocation support

Add an optional `Observer` parameter to `Invoke-P4` that, when provided,
is called instead of the module-scoped `$script:P4ExecutionObserver`. Existing
callers continue to work via the module-scoped default. This removes the
session-global observer bottleneck (C7) and enables safe async execution later.

Signature addition:

```powershell
function Invoke-P4 {
    param(
        ...existing params...
        [scriptblock]$Observer = $null
    )
    # At observer invocation point:
    $effectiveObserver = if ($null -ne $Observer) { $Observer } else { $script:P4ExecutionObserver }
    if ($effectiveObserver) { & $effectiveObserver ... }
}
```

### 0.3 Define shared command/result records

Create one shared command-result shape used by both the busy/history modal and
the command log:

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

Both command-history surfaces consume this record, ensuring consistent taxonomy.

### 0.4 Add a cache-status sibling dictionary

Introduce `State.Data.FileCacheStatus` as a separate dictionary keyed by
`cacheKey`. Values are string status labels:

```text
'NotLoaded' | 'LoadingBase' | 'BaseReady' | 'LoadingEnrichment' | 'Ready' | 'EnrichmentFailed'
```

Keep `FileCache` itself as raw `FileEntry[]` — no shape change needed.

### 0.5 Add an executor seam and idle-tick helper

Define a DI seam for command execution. Production uses
`Invoke-BrowserSideEffect`. Tests use an inline executor that runs
synchronously and returns deterministic completions.

Suggested interface shape:

```powershell
[pscustomobject]@{
    Execute    = [scriptblock]  # { param($CommandLine, $WorkItem, $State) → state }
    IsComplete = [scriptblock]  # { param($RequestId) → $bool }
    GetResult  = [scriptblock]  # { param($RequestId) → completion payload }
}
```

### 0.6 Introduce request envelope for PendingRequest

Enrich the `PendingRequest` signal with identity and scope:

```powershell
@{
    RequestId   = 'req-17'
    Kind        = 'LoadFilesBase'
    Scope       = 'Files'
    CacheKey    = '123:Opened'
    Generation  = 4
}
```

This still works synchronously, but creates the identity needed for M4
stale-result handling.

## Affected Files

- `PerfourceCommanderConsole.psm1` — workflow normalization, executor seam
- `tui/Reducer.psm1` — request envelope, cache status
- `p4/P4Cli.psm1` — observer-per-invocation

## Acceptance Criteria

- All workflows use `Invoke-BrowserWorkflowCommand` for individual items.
- Startup `Get-P4Info` goes through the side-effect gateway.
- `Invoke-P4` accepts an optional per-invocation observer callback.
- `FileCacheStatus` dictionary tracks load phases.
- Requests carry stable identity and scope.
- Modal history and command log share one outcome taxonomy.
- A future async executor can be swapped in without redesigning the reducer.

## Tests

- Workflow execution: verify all four workflows produce observer events for
  each individual item (via mock `Register-P4Observer`).
- Request envelope: verify `RequestId` and `Generation` are populated.
- Shared command record: verify outcome taxonomy covers Completed, Failed,
  TimedOut, Cancelled.
- Cache status: verify `FileCacheStatus` transitions for opened-file load path.
- Executor seam: verify inline test executor produces identical state as
  production path.
- `Copy-BrowserState` round-trip: verify new `FileCacheStatus` dictionary
  survives deep copy (shared by reference, same as other dictionaries).

---

# Milestone 1 — Instrumentation and Static UX

## Objective

Make waits more understandable and diagnosable without changing the synchronous
execution model.

## Scope

### 1.1 Add shared thresholds and command-category policy

Define named policy objects in `P4Cli.psm1`:

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

Add a command-category resolver:

```powershell
function Get-P4CommandCategory {
    param([string[]]$P4Args)
    switch ($P4Args[0]) {
        { $_ -in 'fstat','opened','filelog','diff' } { return 'FileQuery' }
        { $_ -in 'change','reopen','shelve' }        { return 'Mutating' }
        'describe'                                    { return 'Describe' }
        default                                       { return 'Metadata' }
    }
}
```

Add a duration-class resolver:

```powershell
function Get-DurationClass {
    param([int]$DurationMs)
    if ($DurationMs -ge $script:CommandThresholds.CriticalMs) { return 'Critical' }
    if ($DurationMs -ge $script:CommandThresholds.WarningMs)  { return 'Warning' }
    if ($DurationMs -ge $script:CommandThresholds.InfoMs)     { return 'Info' }
    return 'Normal'
}
```

### 1.2 Improve the static busy modal

The modal is still static in this milestone. Improve the text to be
informative and honest:

- Header/body: `[⏳] Running: p4 fstat ...`
- Footer: `[ℹ] Waiting for Perforce. Timeout: 30s`

When a workflow is active, show static step progress:

- `[⏳] Working… (step 2/5)`

### 1.3 Improve both command-history surfaces

Apply the shared classification model to:

- modal history rows,
- command log rows,
- command detail pane,
- command log filters.

Include:

- duration color classes (Normal / Info / Warning / Critical),
- explicit `TimedOut` and `Cancelled` outcomes alongside `Completed` and `Failed`,
- prominent subcommand display,
- status filters in the command log beyond just OK/Error.

### 1.4 Category-aware default timeouts

Allow `Invoke-P4` callers to override timeout explicitly. When no override is
supplied, resolve a category-aware default via `Get-P4CommandCategory` +
`$script:P4TimeoutByCategory`.

## Acceptance Criteria

- Busy modal shows static text with command name and timeout.
- Command log and modal history use the same duration/outcome taxonomy.
- Timeouts are category-aware and centrally defined.
- Existing command flows behave normally.

## Tests

- `Get-P4CommandCategory` returns correct category for each p4 subcommand.
- `Get-DurationClass` returns correct class for boundary values.
- Timeout resolution uses category default when no explicit override is given.
- Command log filter predicates handle new outcome values.
- Busy modal copy includes command name and step progress text.

---

# Milestone 2 — Faster Synchronous First Paint

## Objective

Reduce blocking time in common workflows without introducing background
execution.

## Scope

### 2.1 Split opened-files loading into base load + enrichment

Change `Invoke-BrowserFilesLoad` from:

```text
fstat + diff -sa enrichment + state update
```

to:

```text
Request A: base file load (fstat)
→ set FileCacheStatus = 'BaseReady'
→ return to main loop and render

Request B: content-diff enrichment (diff -sa)
→ set FileCacheStatus = 'Ready'
→ re-render when done
```

The reducer signals enrichment as a follow-up `PendingRequest` after base load
completes. A new `PendingRequest.Kind = 'LoadFilesEnrichment'` is added.

### 2.2 Use FileCacheStatus for load-phase tracking

Use the sibling dictionary from M0.4:

```text
NotLoaded → LoadingBase → BaseReady → LoadingEnrichment → Ready
                                          └────────────→ EnrichmentFailed
```

The reducer sets status at each transition. Render logic reads it.

### 2.3 Render partially enriched state clearly

When `FileCacheStatus[$cacheKey]` is `BaseReady` or `LoadingEnrichment`:

- Render a pending glyph (`…`) in the content-modified column.
- Show a status-bar note: "Content status: loading…"
- Do not show "clean" as the content-modified state.

### 2.4 Make enrichment idempotent and demand-driven

The reducer checks `FileCacheStatus` before signaling enrichment:

- If status is already `LoadingEnrichment` or `Ready`, do not re-request.
- Good triggers: files screen opened, content-status column visible,
  user explicitly reloads.

### 2.5 Per-enrichment-step timeout budget

For `Get-P4ChangelistEntries` unresolved enrichment, add a time budget:

```powershell
$enrichmentBudget = $script:EnrichmentBudgetMs  # e.g. 5000
$enrichmentStarted = Get-Date
foreach ($changeNumber in $changeNumbers) {
    if (((Get-Date) - $enrichmentStarted).TotalMilliseconds -gt $enrichmentBudget) {
        break  # abandon remaining enrichment gracefully
    }
    # ... per-CL fstat
}
```

This provides a ceiling for the worst-case synchronous enrichment path.

## Acceptance Criteria

- Opening the files screen reaches first paint without waiting for
  `p4 diff -sa`.
- UI distinguishes "pending enrichment" from "clean".
- Reload and re-entry stay idempotent.
- Unresolved enrichment respects a time budget.

## Tests

- File-load status transitions: `NotLoaded → LoadingBase → BaseReady →
  LoadingEnrichment → Ready`.
- `EnrichmentFailed` status when `diff -sa` throws.
- Files first paint: state after base load has entries but `IsContentModified`
  is not set.
- Enrichment idempotence: second load request when status is already `Ready`
  does not trigger a new request.
- Pending indicator rendering: render output includes `…` when status is
  `BaseReady`.
- Time-budget: enrichment loop stops when budget is exceeded; remaining CLs
  have `UnresolvedFileCount = 0`.

---

# Milestone 3 — Busy-State Control and Semantics

## Objective

Improve user control within the synchronous architecture by acting at safe
checkpoints.

## Scope

### 3.1 Add `CancelRequested` and `QuitRequested` state

Add to `Runtime`:

```powershell
CancelRequested = $false
QuitRequested   = $false
```

While still synchronous, cancel means: stop after the current safe step,
not interrupt the currently running native process.

### 3.2 Define busy-state key precedence

When busy:

1. `Escape` cancels active overlay if one is open.
2. Otherwise `Escape` sets `CancelRequested = $true`.
3. `Q` sets `QuitRequested = $true`.
4. Hide/dismiss behavior only applies when not busy.

### 3.3 Poll between workflow items via injected cancel check

Workflow executors currently have natural checkpoint boundaries (the
`foreach ($changeId in $changeIds)` loops). Between items:

- Check for cancel/quit via an injected `$CheckCancel` callback (not direct
  `[Console]::KeyAvailable`, for testability).
- If cancelled, dispatch `WorkflowEnd` cleanly and return.

Suggested callback shape:

```powershell
$CheckCancel = {
    while ([Console]::KeyAvailable) {
        $key = [Console]::ReadKey($true)
        $action = ConvertFrom-KeyInfoToAction -KeyInfo $key -State $state
        if ($action.Type -eq 'HideCommandModal') { return 'Cancel' }
        if ($action.Type -eq 'Quit')             { return 'Quit' }
    }
    return 'Continue'
}
```

In tests, the callback returns a deterministic sequence.

### 3.4 Improve modal messaging for workflow state

- `[⏳] Working… (step 2/5)`
- `[⚠] Cancel requested — finishing current step…`
- `[⚠] Will quit after current command…`

### 3.5 Split more compound synchronous work into checkpoints

The file-load split (M2) is the first case. Additional candidates:

- Pending changelist enrichment phases.
- Multi-file workflow operations.

## Acceptance Criteria

- User can request cancel between workflow steps.
- User can request quit while busy and exit cleanly afterwards.
- Modal/footer language reflects busy-state intent.
- All workflows use the same busy/cancel semantics.
- Cancel-check is injected (DI-friendly), not hardcoded to `[Console]`.

## Tests

- Busy-state key precedence: overlay dismiss before cancel.
- Cancel request between workflow items: workflow stops after current item.
- Deferred quit: `QuitRequested` is set; loop exits after command completes.
- Injected cancel callback: test executor returns 'Cancel' on second item;
  verify `WorkflowEnd` is dispatched with partial completion.
- Workflow progress footer: verify correct step count in modal text.

---

# Milestone 4 — Async Read-Only Execution

## Objective

Keep the UI responsive during long-running **read-only** operations.

Start with read-only commands only. That yields most of the user benefit with
much lower correctness risk than async mutation.

## Scope

### 4.1 Introduce one foreground async lane

One active foreground request at a time. Candidates:

- pending reload,
- submitted reload,
- files base load,
- files enrichment,
- describe fetch.

Do not start with multiple simultaneous foreground commands.

### 4.2 Use an executor abstraction

**Production executor:**

- Starts a background worker via `Start-ThreadJob` (built-in since PS 7.0).
- Imports required modules in the worker runspace.
- Runs typed read-only work.
- Returns typed completion payloads via a thread-safe queue or `Receive-Job`.
- Uses per-invocation observer callback (from M0.2) — the worker passes its
  own observer, captured observation data is returned with the completion
  payload.

**Test executor:**

- Runs inline, synchronously.
- Returns deterministic completions.
- No thread timing flakiness.

### 4.3 Redesign the main loop to drain completions during idle

The loop must do work even when no key is pressed:

```text
Render
Poll Input (non-blocking)
Check Resize
Drain Completion Queue   ← NEW
Dispatch Reducer Actions
Sleep 50 ms
```

The completion drain step checks whether the active foreground job has
completed. If so, it extracts the typed payload and dispatches the
corresponding reducer action.

### 4.4 Main-thread-only cache writes (critical safety rule)

Background workers return data payloads. **Only the main thread writes to
shared caches** (FileCache, DescribeCache, CommandOutputCache). This is
enforced by the completion-queue pattern: the worker returns data, the
main-loop drain step calls the reducer, and the reducer updates state
(including caches).

This avoids all PowerShell hashtable thread-safety issues without requiring
`ConcurrentDictionary`.

### 4.5 Keep only scalar async state in reducer state

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

Live job handles and process objects live in a module-scoped registry keyed by
`RequestId`, outside reducer state.

### 4.6 Use typed completion actions

```text
PendingChangesLoaded   — carries fresh AllChanges array
FilesBaseLoaded        — carries FileEntry[] for CacheKey
FilesEnrichmentDone    — carries enriched FileEntry[] for CacheKey
DescribeLoaded         — carries describe data for Change
CommandFailed          — carries error details
CommandObserved        — carries observer data for command log integration
```

Workers return payload data only. The reducer updates state.

### 4.7 Generation-based stale-result protection

Define generation counters:

- `State.Data.PendingGeneration` — incremented on pending reload or view switch.
- `State.Data.SubmittedGeneration` — incremented on submitted reload.
- `State.Data.FilesGeneration` — incremented per cache key when a new file
  load request is issued.

Each async completion carries the generation it was requested under. The
reducer drops completions where `completion.Generation < currentGeneration`.

### 4.8 Request conflict resolution

When a new request arrives while an in-flight request is active:

- **Same scope:** Cancel the in-flight request (set `Cancelling` status,
  attempt to kill the background job). The new request becomes active.
  The old request's completion, if it arrives, is dropped via generation check.
- **Different scope:** Queue the new request. The single-lane model means it
  waits until the current request completes.

State shape:

```powershell
Runtime.ActiveCommand  = ...   # currently in-flight (nullable)
Runtime.PendingRequest = ...   # next-up (nullable, latest-wins per scope)
```

### 4.9 Enable live elapsed-time display

Once the main loop stays alive, the busy modal reads
`Runtime.ActiveCommand.StartedAt` and displays a live timer:

```text
[⏳] Running: p4 fstat ...  (3.2s)
```

Elapsed time is recomputed on each render tick. No state mutation needed —
the render function computes it from the immutable `StartedAt` value.

### 4.10 Preserve command observation and logging

The async worker captures observer events using its per-invocation observer
callback (from M0.2). On completion, the payload includes structured
observation data:

```powershell
@{
    ObservedCommands = @(
        @{ CommandLine = ...; DurationMs = ...; ExitCode = ...; ... }
    )
}
```

The main-loop drain step dispatches `LogCommandExecution` actions for each
observed command, preserving command log functionality.

## Acceptance Criteria

- UI stays responsive during long-running read-only commands.
- Completions are applied without requiring a keypress.
- Live elapsed time updates in the busy modal.
- Stale results are safely ignored via generation checks.
- Command logging still works.
- All cache writes happen on the main thread only.

## Tests

- **Idle loop drains completions:** fake executor completes; reducer action
  dispatched without keypress.
- **Active command lifecycle:** `Running → Completed` transition.
- **Stale-result dropping:** completion with old generation is ignored.
- **Request conflict:** new same-scope request cancels in-flight request.
- **Live elapsed time:** render function computes correct elapsed from
  `StartedAt`.
- **Command observation:** async worker returns observer data; command log
  entries are created.
- **Cache write safety:** verify all cache mutations happen via reducer
  actions, not in worker scriptblocks.
- **`Copy-BrowserState` round-trip:** verify `ActiveCommand` and generation
  counters survive deep copy correctly.

---

# Milestone 5 — Async Mutation and True Cancellation

## Objective

Extend the async model to mutating workflows and add true cancel semantics.

This milestone should happen only after read-only async behavior is stable.

## Scope

### 5.1 Add process-aware cancellation

Factor the existing `taskkill /F /T /PID` logic from `Invoke-P4` into a
shared helper:

```powershell
function Stop-P4ProcessTree {
    param([int]$ProcessId)
    try { $null = & taskkill /F /T /PID $ProcessId 2>&1 } catch { }
}
```

Cancel flow:

1. User presses `Escape`.
2. Reducer marks `Runtime.ActiveCommand.Status = 'Cancelling'`.
3. Main-loop drain step looks up the job handle from the module registry.
4. Calls `Stop-P4ProcessTree` with the active PID.
5. Stops/cleans up the background job.
6. Dispatches `CommandCancelled` action to the reducer.

### 5.2 Report process lifecycle events

Compound operations may launch more than one native `p4` process. Allow
worker-to-main-thread lifecycle events:

- `ProcessStarted { RequestId; ProcessId }`
- `ProcessFinished { RequestId; ProcessId; ExitCode }`

The module registry tracks the current PID so cancel can target it.

### 5.3 Distinguish outcomes clearly

User-visible outcomes:

- `Completed`
- `Failed`
- `TimedOut`
- `Cancelled`

These drive modal tags, command log filters, detail pane text, and any
future analytics.

### 5.4 Expand async support to mutating workflows

Once cancellation is proven for reads, extend to:

- delete changelist,
- delete shelved files,
- shelve files,
- move/reopen workflows.

Keep workflow progress explicit and reducer-driven. The workflow executor
wraps each item in the async executor and drains completions between items.

### 5.5 Allow limited interaction while a command runs

Once the main loop is alive during async work, safe interactions remain
enabled:

- command log browsing,
- command output preview,
- scrolling history,
- viewing active command details.

General navigation (switching views, opening files screen) should remain
blocked until explicit conflict rules are designed.

## Acceptance Criteria

- User can truly cancel a running command.
- Cancelled, timed out, and failed outcomes are distinct everywhere.
- Async mutation follows the same lifecycle as async reads.
- Partial progress and workflow outcome remain understandable.
- Process-tree kill uses shared helper (no duplication with `Invoke-P4`).

## Tests

- Cancel lifecycle: `Running → Cancelling → Cancelled` transition.
- `Stop-P4ProcessTree` kills child process tree.
- Timeout vs cancel vs failure: distinct outcomes in state and command log.
- Process lifecycle events: `ProcessStarted`/`ProcessFinished` update registry.
- Race: cancel arrives after completion — completion wins, cancel is no-op.
- Race: timeout fires after cancel — cancel outcome takes precedence.
- Async mutation workflow: items complete/fail individually; `WorkflowEnd`
  dispatched correctly.

---

## Cross-Cutting Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Shared-reference caches hide mutable-state bugs | stale or incorrect UI | enforce main-thread-only cache writes via completion queue (M4.4) |
| Completion queue not drained during idle | async UI appears frozen | redesign main loop around idle tick (M4.3) |
| Worker scriptblocks become stateful | brittle async logic | workers return typed data only, never mutated state (Rule 2) |
| `Stop-Job` does not kill native child process | cancel appears broken | use `Stop-P4ProcessTree` (factored from existing `Invoke-P4` logic) |
| Session-global observer clobbered by concurrent workers | lost command log data | per-invocation observer callback (M0.2, Rule 9) |
| Command outcomes differ between modal and command log | inconsistent UX | shared command record schema (M0.3) |
| Thread-job import overhead on short commands | perceptible latency | accept initially; consider runspace pooling later if measured |
| `PendingRequest` clobbered by rapid user actions | lost request | explicit ActiveCommand + PendingRequest pair with conflict resolution (M4.8) |

---

## Testing Strategy

### Guiding Principles

- Run Pester in a fresh `pwsh -NoProfile` process.
- Use DI so orchestration tests do not depend on live Perforce.
- Test behavior and contracts, not raw constant values.
- Normalize 0..N results with `@(...)` at call boundaries.
- Add explicit reducer action-contract tests for every new action type
  (given state S and action A, assert state S').
- Add state-copy round-trip tests for new properties.
- Add render contract tests for new UI states.

### Unit Tests by Milestone

**Milestone 0–1:**

- Workflow execution normalization (observer events for each workflow item).
- Request envelopes carry identity and scope.
- Shared command outcome classification.
- Timeout resolution by command category.
- Duration-class resolution at boundary values.
- Command-category resolution for each p4 subcommand.
- Busy modal copy includes command name and step progress.
- Command log filters support richer outcomes.
- `Copy-BrowserState` round-trip for `FileCacheStatus`.

**Milestone 2:**

- File-load status transitions (full state machine).
- Files first paint before enrichment.
- Enrichment idempotence (no duplicate request).
- Pending indicator rendering (`…` glyph).
- Reload semantics with partial data.
- Per-enrichment-step time budget.

**Milestone 3:**

- Busy-state key precedence.
- Cancel request between workflow items.
- Deferred quit.
- Injected cancel callback — deterministic test sequence.
- Workflow progress footer messaging.

**Milestone 4:**

- Idle loop drains completions without keypress.
- Active command lifecycle transitions.
- Stale-result dropping via generation.
- Request conflict resolution (same-scope cancellation).
- Live elapsed-time formatting.
- Command observation survives async execution.
- All cache writes via reducer (not worker).

**Milestone 5:**

- Cancel lifecycle (Running → Cancelling → Cancelled).
- `Stop-P4ProcessTree` behavior.
- Timeout vs cancel vs failure outcome distinctions.
- Process lifecycle events.
- Async mutation workflow progress.
- Race: cancel vs completion.
- Race: timeout vs completion.

### Integration Tests

- Open files screen: base load first, enrichment later.
- Pending reload while idle receives completion.
- Stale file-load completion ignored after navigation or reload.
- Deferred quit during busy operation.
- Async foreground read completes and updates UI.
- Cancellation reports the correct outcome.

### Async Smoke Tests (keep few and focused)

- Completion arrives with no keypress.
- Stale completion is discarded.
- Cancel kills the active process.
- Timeout cleanup path works.

Most async behavior should be covered by deterministic fake-executor tests.

---

## Recommended Delivery Order

### Release A

- Milestone 0 (foundation)
- Milestone 1 (instrumentation)
- Opened-files base/enrichment split from Milestone 2

### Release B

- Remaining Milestone 2 work (status tracking, time budget, render)
- Milestone 3 (busy-state control)

### Release C

- Milestone 4 (async read-only)

### Release D

- Milestone 5 (async mutation and cancel)

---

## Recommended First Implementation Slice

If implementation starts immediately:

1. Normalize `MoveMarkedFiles` per-item execution (M0.1).
2. Wrap startup `Get-P4Info` in `Invoke-BrowserSideEffect` (M0.1).
3. Add per-invocation observer parameter to `Invoke-P4` (M0.2).
4. Introduce `FileCacheStatus` sibling dictionary (M0.4).
5. Add command-category resolver and duration-class helpers (M1.1).
6. Improve static busy modal text (M1.2).
7. Split opened-files load into base + enrichment (M2.1).

This slice produces user-visible value quickly and reduces later architectural
risk.

---

## Future Extensions

Once the core plan is stable:

- **Progressive changelist enrichment:** Load base CLs + opened counts first,
  enrich shelved and unresolved counts progressively. Same base/enrichment
  pattern as files.
- **Speculative describe prefetch:** When user focuses a changelist,
  speculatively fetch `p4 describe` in a low-priority lane. Generation
  mechanism handles stale prefetches.
- **Background re-enrichment on focus:** When returning to the files screen,
  silently re-verify content-modified status to catch external changes.
- **Command output streaming:** For very long `p4 fstat` results, show a live
  record count in the busy modal (e.g., "Loaded 1,234 files…") via a shared
  counter.
- **Low-priority background enrichment lane:** A second async lane for
  non-urgent enrichment that runs behind the foreground request.
- **Runspace pooling:** Pre-import modules into a runspace pool to reduce
  per-job overhead for frequent short commands.
- **Adaptive timeout policy:** Track observed durations per command category
  and adjust timeouts to 3× the p95 rather than fixed values.
- **Debug surface:** Internal diagnostics view showing active requests,
  generations, and dropped stale results.

---

## Final Guidance

> Build a small architectural foundation first, then add async read-only
> execution, and only then extend to true cancel and async mutation.

The most critical safety rule is **main-thread-only cache writes** (M4.4).
Honoring this single constraint prevents the entire class of shared-state
concurrency bugs that would otherwise make the async model fragile.

The second most important preparation is **per-invocation observer support**
(M0.2). Without it, async workers cannot safely log commands, and the
command-log surface breaks under any concurrent execution.

Everything else follows incrementally from these two foundations.
