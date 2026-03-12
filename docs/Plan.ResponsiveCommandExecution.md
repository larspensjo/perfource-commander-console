# PerFourceCommanderConsole — Responsive Long-Running Command Plan

## Problem Summary

The current TUI becomes effectively hard-blocked while a long-running `p4` command is executing.

Observed symptoms:

- The UI shows a busy modal with `Running:` and `Please wait...`
- Keyboard input is not processed until the command returns
- `Ctrl+C` is not a reliable escape hatch from the user's perspective
- For the slow path of opening files, the TUI can be blocked by both:
  - the initial `p4 fstat` query
  - follow-up enrichment such as `p4 diff -sa`

This plan describes a staged path from low-risk UX wins to a fully responsive, cancelable command execution model.

---

## Goals

1. Make long-running operations feel understandable rather than frozen.
2. Reduce the amount of time the TUI is blocked on common workflows.
3. Add user control during slow operations.
4. Reach a long-term architecture where the TUI remains interactive while commands run.
5. Support true cancellation and safe handling of stale results.

---

## Non-Goals

For the early milestones, this plan does **not** require:

- Parallelizing all Perforce operations at once
- Streaming raw `p4` output live into the UI
- Rewriting the entire reducer architecture
- Adding complex job scheduling or persistence

Those can come later if the background execution model proves useful.

---

## Current Architecture (Code-Level Baseline)

Understanding the current architecture is essential for knowing what each milestone must change and what it can reuse.

### Main loop (`Start-P4Browser`)

The main loop follows strict Unidirectional Data Flow:

```
State → Render → Poll Input → Map to Action → Reducer (pure) → Side Effects → State'
```

Input polling uses a busy-wait loop with `[Console]::KeyAvailable` + 50 ms sleep, which also detects console resize. This loop does **not** run while I/O is executing.

### Side-effect gateway (`Invoke-BrowserSideEffect`)

**All** I/O flows through this single function:

1. Dispatches `CommandStart` action → sets `ModalPrompt.IsBusy = $true`
2. Renders the busy modal (one static frame)
3. Registers a P4 observer to capture command metadata
4. Executes `$WorkItem` **synchronously** (blocking the main thread)
5. Unregisters observer, dispatches `LogCommandExecution` for each captured call
6. Dispatches `CommandFinish` → clears busy state

Because the main thread is blocked at step 4, the UI cannot update and input cannot be polled during command execution.

### Reducer (`Invoke-BrowserReducer`)

The reducer is pure — it never performs I/O. Side effects are requested by setting `$state.Runtime.PendingRequest = @{ Kind = '...' }`, which the main loop consumes after the reducer returns. Key state related to command execution:

- `Runtime.ModalPrompt.IsBusy` / `.IsOpen` / `.CurrentCommand` / `.History`
- `Runtime.PendingRequest` — one-shot side-effect signal
- `Runtime.ActiveWorkflow` — progress tracking for multi-step workflows

### P4 CLI (`Invoke-P4`)

- Spawns `System.Diagnostics.Process` with redirected stdout/stderr
- Reads both streams via `ReadToEndAsync()` to avoid pipe deadlocks
- 30 s default timeout via `WaitForExit($TimeoutMs)`
- On timeout: `taskkill /F /T /PID` (tree kill), then `Process.Kill()` fallback, then `Dispose()`
- Single-slot observer pattern (`Register-P4Observer`) captures command metadata

### Busy modal rendering

- Static box panel showing `"Running: <command>"` in yellow
- Footer: `"Please wait..."` — no elapsed time, no cancel hint
- History rows show completed commands with `[OK]`/`[ERR]` tags and duration

### File loading and enrichment

For opened files, `Invoke-BrowserFilesLoad` executes inside one blocking `Invoke-BrowserSideEffect`:

1. `Get-P4OpenedFiles` — fstat query
2. `Get-P4ModifiedDepotPaths` — `p4 diff -sa` (expensive)
3. `Set-P4FileEntriesContentModifiedState` — stamps `IsContentModified`

For changelist entries, `Get-P4ChangelistEntries` runs 4 sequential calls:

1. `Get-P4PendingChangelists` — base list
2. `Get-P4OpenedFileCounts` — opened file counts per CL
3. `Get-P4ShelvedFileCounts` — shelved counts (batched describe)
4. `Get-P4UnresolvedFileCounts` — unresolved counts (per-CL fstat)

Calls 2–3 are independent and could run concurrently.

### Workflow pattern

Workflow executors (delete, move, shelve) use item-level granularity:
`WorkflowBegin → (WorkflowItemComplete | WorkflowItemFailed)* → WorkflowEnd`.
This already provides natural checkpoint boundaries between items.

---

## Constraints

### C1: Main thread is blocked during I/O

The current architecture cannot poll input, update the timer, or respond to resize while `Invoke-BrowserSideEffect` is executing. Any feature that requires interactivity during a command must either (a) use a background thread for the command, or (b) use a background thread for the UI update (e.g., a timer).

### C2: `[Console]` is not thread-safe

If a background thread writes to `[Console]` while the main thread also writes, output corruption is likely. Any concurrent console access must be serialized.

### C3: PowerShell runspace isolation

`Start-ThreadJob` runs in a separate runspace. Modules must be re-imported, and variables are marshalled by value. The observer scriptblock must be invokable from the background runspace or results must flow back via a thread-safe channel.

### C4: `IsContentModified` defaults to `$false`

The current `New-P4FileEntry` sets `IsContentModified = $false`. Representing "not yet loaded" requires either a `$null` sentinel (tri-state) or a separate `EnrichmentStatus` field on the file entry or the cache entry.

---

## Strategy Summary

Deliver the improvements in five milestones:

1. **Milestone 1 — Clarity and instrumentation**
2. **Milestone 2 — Faster common paths**
3. **Milestone 3 — Checkpoint-based control within synchronous execution**
4. **Milestone 4 — Background execution architecture**
5. **Milestone 5 — True cancellation and polished long-running-command UX**

The milestones are intentionally incremental. Each milestone should be shippable on its own.

---

## Milestone Overview

| Milestone | Theme | Main Benefit | Risk |
|---|---|---|---|
| 1 | Visibility | Users understand what is happening | Low |
| 2 | Performance | Less time spent blocked in common paths | Low–Medium |
| 3 | Control | Safer UX and checkpoint-based escape | Medium |
| 4 | Architecture | UI stays responsive while commands run | High |
| 5 | Polish | True cancel + professional command UX | High |

---

# Milestone 1 — Clarity and Instrumentation

## Objective

Make long waits feel intentional and diagnosable before changing the execution model. All changes are within the existing synchronous architecture.

## Scope

### 1.1 Add slow-command instrumentation

Track command durations with named threshold constants (no naked constants) shared via the `P4Cli` module:

```powershell
$script:CommandThresholds = [pscustomobject]@{
    InfoMs     = 500    # start tracking
    WarningMs  = 2000   # annotate in command log
    CriticalMs = 5000   # highlight prominently
    TimeoutMs  = 15000  # default short-command timeout
}
```

The existing observer already captures `$StartedAt`, `$EndedAt`, `$DurationMs`. Extend the `LogCommandExecution` action to classify each command against these thresholds.

#### Deliverables

- Threshold-classified entries in command history
- Slow commands identifiable from logs and tests
- Foundation for future optimization targeting

### 1.2 Improve busy modal copy

Since the main thread is blocked during I/O (constraint C1), the busy modal cannot show a live elapsed-time counter in M1. Instead, improve the **static** content shown before the blocking call:

| Before | After |
|---|---|
| `Running: p4 fstat ...` | `[⏳] Running: p4 fstat ...` |
| `Please wait...` | `[ℹ] Waiting for Perforce. Timeout: 30s` |

Use UTF-8 glyphs (per project guidelines) and the `$CommandThresholds.TimeoutMs` value to show the applicable timeout.

> **Note:** Live elapsed-time display requires the main loop to remain active (Milestone 4). A lighter alternative — using `[System.Threading.Timer]` to update just the timer cell from a background callback — is possible but risks console corruption (constraint C2) and is not recommended before M4.

### 1.3 Improve command log surfacing

Enhance history rows in the command modal:

- Color-code duration by threshold: green (< Info), yellow (≥ Warning), red (≥ Critical)
- Show `[TIMEOUT]` distinctly from `[ERR]`
- Show the p4 subcommand prominently (e.g., `fstat`, `diff`, `changes`)

Extend `Format-P4OutputLine` or the observer event to extract the p4 subcommand.

### 1.4 Tune timeouts per command class

Introduce command-class-aware timeout defaults. The current flat 30 s default is too generous for metadata queries and too tight for large file operations.

Suggested categories and values (using named constants):

```powershell
$script:P4TimeoutByCategory = @{
    Metadata  = 10000   # info, changes, opened
    FileQuery = 30000   # fstat, diff -sa
    Mutating  = 30000   # shelve, reopen, change -d
    Describe  = 15000   # describe -s
}
```

Add a helper that resolves the timeout from the command arguments:

```powershell
function Get-P4TimeoutForArgs {
    param([string[]]$P4Args)
    $subcommand = $P4Args | Where-Object { $_ -notmatch '^-' } | Select-Object -First 1
    switch ($subcommand) {
        'info'     { return $script:P4TimeoutByCategory.Metadata }
        'changes'  { return $script:P4TimeoutByCategory.Metadata }
        'opened'   { return $script:P4TimeoutByCategory.Metadata }
        'fstat'    { return $script:P4TimeoutByCategory.FileQuery }
        'diff'     { return $script:P4TimeoutByCategory.FileQuery }
        'describe' { return $script:P4TimeoutByCategory.Describe }
        default    { return $script:P4TimeoutByCategory.Mutating }
    }
}
```

## Files Touched

- `p4/P4Cli.psm1` — thresholds, timeout categories, observer extension
- `tui/Render.psm1` — `Build-CommandModalRows` improvements
- `tui/Reducer.psm1` — `LogCommandExecution` handler: classify by threshold
- `tui/Theme.psm1` — add glyphs for timer/warning/timeout
- `tests/Render.Tests.ps1` — busy modal rendering tests
- `tests/Reducer.Tests.ps1` — threshold classification tests
- `tests/P4Cli.Tests.ps1` — timeout category resolution tests

## Acceptance Criteria

- Busy modal shows a clearer status with timeout information.
- Command log displays duration color-coded by threshold.
- Timeouts are category-aware and consistent.
- No behavior regressions in normal command flows.
- All changes covered by Pester unit tests.

## Pros

- Very low risk — no execution model changes
- Immediate UX benefit
- Better evidence for later optimization

## Cons

- Does not solve the underlying blocking problem
- Elapsed time counter deferred to M4

---

# Milestone 2 — Faster Common Paths

## Objective

Reduce synchronous blocking time in the most common slow workflows without changing the execution model.

## Scope

### 2.1 Split file loading into fast path and enrichment path

Restructure `Invoke-BrowserFilesLoad` so the first paint of the files screen does not wait on `p4 diff -sa`:

**Current** (one blocking call):
```
Invoke-BrowserSideEffect:
  1. Get-P4OpenedFiles       (fstat)
  2. Get-P4ModifiedDepotPaths (diff -sa)  ← expensive
  3. Set-P4FileEntriesContentModifiedState
  ↓ return to main loop
```

**New** (two separate side effects):
```
Invoke-BrowserSideEffect #1:
  1. Get-P4OpenedFiles       (fstat)
  ↓ return to main loop, render file list

Invoke-BrowserSideEffect #2 (triggered by new PendingRequest):
  2. Get-P4ModifiedDepotPaths (diff -sa)
  3. Set-P4FileEntriesContentModifiedState
  ↓ return to main loop, re-render with enriched data
```

The reducer emits a `LoadFiles` request for step 1, then on success the side-effect handler emits an `EnrichFiles` request for step 2. The user sees the file list after step 1 completes, with content-modified status showing as pending.

### 2.2 Represent enrichment state in the data model

Introduce an enrichment status to distinguish "not loaded" from "loaded as false":

**Option A — tri-state `IsContentModified`:** Change `New-P4FileEntry` to default `IsContentModified = $null` (nullable). `$null` = not yet checked, `$true` = modified, `$false` = not modified.

**Option B — cache-level enrichment flag:** Add `EnrichmentStatus` to the file cache entry (not individual files). This avoids scattered `$null` checks across the codebase.

Recommendation: **Option B.** The file cache value becomes:

```powershell
@{
    Files            = @(...)       # FileEntry[]
    EnrichmentStatus = 'Pending'    # 'Pending' | 'Loading' | 'Complete' | 'Failed'
}
```

This aligns with the UDF pattern — enrichment state is part of the data model, not hidden in ad-hoc fields.

### 2.3 Make enrichment demand-driven

Only compute expensive metadata when it is needed:

| Trigger | Enrichment |
|---|---|
| File list is visible | Base file data (fstat) — always loaded |
| User opens a detail view | Content-modified state |
| A filter depends on `IsContentModified` | Content-modified state |
| Column for modified content is visible | Content-modified state |

The enrichment request should be idempotent — if already loaded or loading, skip.

### 2.4 Add visual state for partially enriched data

When enrichment is pending, the UI should communicate this clearly:

- Modified column: `·` (middle dot) or `…` instead of the `≠` glyph
- Status bar: `Files: 42 loaded  (enrichment pending)` or `Files: 42 loaded ✓`
- Use theme glyphs for consistency

Add to `Theme.psm1`:

```powershell
EnrichmentPending = '…'
EnrichmentFailed  = '✗'
```

### 2.5 Parallelize independent enrichment calls (optional)

`Get-P4ChangelistEntries` runs opened-file counts and shelved-file counts sequentially, but they are independent. Use `Start-ThreadJob` to run them concurrently:

```powershell
$openedJob  = Start-ThreadJob { Import-Module ...; Get-P4OpenedFileCounts }
$shelvedJob = Start-ThreadJob { Import-Module ...; Get-P4ShelvedFileCounts }
$opened  = Receive-Job $openedJob  -Wait -AutoRemoveJob
$shelved = Receive-Job $shelvedJob -Wait -AutoRemoveJob
```

This is a contained use of background threads that does not affect the main loop architecture. The main thread still blocks, but for less total time.

> **Risk note:** Module loading in thread jobs adds overhead. Profile before committing — the benefit depends on whether network latency or local processing dominates.

## Files Touched

- `PerfourceCommanderConsole.psm1` — split `Invoke-BrowserFilesLoad`, add `EnrichFiles` request handler
- `p4/P4Cli.psm1` — optionally parallelize `Get-P4ChangelistEntries`
- `p4/Models.psm1` — adjust `IsContentModified` default or add enrichment status
- `tui/Reducer.psm1` — handle `EnrichFiles` pending request, add enrichment state to derived
- `tui/Render.psm1` — render pending enrichment indicator
- `tui/Theme.psm1` — enrichment glyphs
- `tests/Reducer.Tests.ps1` — phased loading tests
- `tests/Render.Tests.ps1` — enrichment indicator rendering

## Acceptance Criteria

- Opening the files screen reaches first paint without waiting for `p4 diff -sa`.
- Enrichment runs automatically after first paint (or on demand).
- The UI clearly distinguishes loaded vs pending enrichment.
- Existing file workflows remain correct.
- Tests cover phased loading and enrichment state transitions.

## Pros

- Good user-visible improvement without architectural change
- Targets the likely hotspot from the reported issue
- Enrichment model is reusable for future metadata (revision history, blame, etc.)

## Cons

- Introduces a second side-effect dispatch per file load
- Some UI surfaces must handle incomplete metadata
- Cache structure changes require updating all consumers

---

# Milestone 3 — Checkpoint-Based Control Within Synchronous Execution

## Objective

Improve user control and safety before full background execution, using the natural checkpoint boundaries that already exist in compound workflows.

## Design Constraint

Since the main thread is blocked during any single `Invoke-P4` call (constraint C1), user input can only be checked **between** side-effect steps. This milestone adds escape hatches at those checkpoints — it does **not** attempt to interrupt a running p4 process (that requires M4/M5).

## Scope

### 3.1 Add inter-step cancellation flag

Add `Runtime.CancelRequested` (bool) to the state. Between workflow steps and between compound side effects, check this flag:

```powershell
# Inside a workflow executor, between items:
if ($state.Runtime.CancelRequested) {
    $state = Invoke-BrowserReducer -State $state -Action @{ Type = 'WorkflowEnd' }
    break
}
```

The flag is set by dispatching a `RequestCancel` action. The reducer sets `CancelRequested = $true` and updates the modal text to `"Cancel requested — will stop after current step…"`.

**When can `RequestCancel` be dispatched?** Between side-effect steps — specifically:

- Between `WorkflowItemComplete`/`WorkflowItemFailed` in multi-item workflows (delete, move, shelve)
- Between the fast-path load and the enrichment load in file loading (new from M2)

### 3.2 Add deferred quit

If the user presses Quit while busy, the state records the intent:

- `Runtime.QuitRequested = $true`
- Modal footer changes to `"Will quit after current command…"`

After the current `Invoke-BrowserSideEffect` returns, the main loop checks `QuitRequested` and exits cleanly.

**Implementation:** Add a `QuitRequested` check after each side-effect dispatch in the main loop:

```powershell
if ($state.Runtime.QuitRequested) {
    $state.Runtime.IsRunning = $false
}
```

### 3.3 Add input polling between workflow steps

Currently, workflow executors loop over items without checking for input. Add a lightweight input check between items:

```powershell
# Between workflow items:
if (Test-BrowserConsoleKeyAvailable) {
    $keyInfo = Read-BrowserConsoleKey
    $action = ConvertFrom-KeyInfoToAction -KeyInfo $keyInfo -State $state
    if ($null -ne $action -and $action.Type -in @('RequestCancel', 'Quit')) {
        $state = Invoke-BrowserReducer -State $state -Action $action
    }
}
```

This gives the user a chance to press Escape or Q between each item in a multi-item workflow, without restructuring the execution model.

### 3.4 Break compound side effects into smaller steps

Where a single `Invoke-BrowserSideEffect` contains multiple sequential p4 calls, refactor into separate `PendingRequest`-driven steps. The M2 file-loading split is the primary example. Other candidates:

- `Invoke-BrowserPendingChangesReload` currently calls `Get-P4ChangelistEntries` which internally runs 4 p4 calls. If performance justifies it, this could be split into base-load + count-enrichment steps.

### 3.5 Improve modal messaging for stateful operations

Evolve the busy modal footer:

| State | Footer |
|---|---|
| Single command busy | `[ℹ] Waiting for Perforce. Timeout: 30s` |
| Workflow step N/M | `[⏳] Working… (step 2/5)   [Esc] Cancel after step` |
| Cancel requested | `[⚠] Cancel requested — finishing current step…` |
| Quit requested | `[⚠] Will quit after current command…` |

Add workflow progress to the modal header row, leveraging `Runtime.ActiveWorkflow.DoneCount` / `.TotalCount`.

## Files Touched

- `PerfourceCommanderConsole.psm1` — input polling between workflow steps, `QuitRequested` check, `CancelRequested` check
- `tui/Reducer.psm1` — `RequestCancel` action, `QuitRequested` state, modal text updates
- `tui/Render.psm1` — stateful footer rendering
- `tui/Input.psm1` — `Escape` → `RequestCancel` mapping when busy
- `tests/Reducer.Tests.ps1` — cancel/quit state transition tests
- `tests/Input.Tests.ps1` — key mapping during busy state

## Acceptance Criteria

- User can press Escape between workflow items to stop after the current step.
- User can press Q during a command to request post-command quit.
- Multi-step operations show step progress.
- Modal footer reflects cancel/quit intent.
- All existing workflow behaviors remain correct.

## Pros

- Meaningful user control without architectural change
- Uses existing checkpoint boundaries (workflow items, split loads)
- Low-risk, incremental

## Cons

- Cannot interrupt a single long-running `Invoke-P4` call
- Input polling between steps adds minor complexity to workflow executors

---

# Milestone 4 — Background Execution Architecture

## Objective

Allow the UI to remain interactive while Perforce commands run by moving command execution off the main thread.

## Key Design Decisions

### D1: Use `Start-ThreadJob` for background execution

PowerShell 7's `Start-ThreadJob` (from `Microsoft.PowerShell.ThreadJob`, built-in) provides lightweight thread-pool-based background execution. Preferred over:

- `Start-Job` — spawns a new process, heavy overhead
- Raw `[System.Threading.Thread]` — requires manual runspace setup
- `ForEach-Object -Parallel` — designed for data parallelism, not long-running tasks

### D2: Use `ConcurrentQueue` for result delivery

Background threads cannot dispatch reducer actions directly (constraint C3). Instead, they enqueue completion events onto a `[System.Collections.Concurrent.ConcurrentQueue[pscustomobject]]` that the main loop drains on each iteration:

```powershell
$script:CompletionQueue = [System.Collections.Concurrent.ConcurrentQueue[pscustomobject]]::new()

# Background thread enqueues:
$script:CompletionQueue.Enqueue([pscustomobject]@{
    RequestId = $requestId
    Kind      = 'CommandComplete'
    Succeeded = $true
    Result    = $data
    ...
})

# Main loop drains:
$completion = $null
while ($script:CompletionQueue.TryDequeue([ref]$completion)) {
    $state = Invoke-BrowserReducer -State $state -Action $completion
}
```

### D3: No concurrent console writes

The background thread must **never** write to `[Console]` (constraint C2). All rendering remains on the main thread. The main loop renders after draining completions.

### D4: Module loading in background runspace

Each `Start-ThreadJob` runs in a fresh runspace. The scriptblock must import `P4Cli.psm1` (and any helpers it needs). Keep the imported surface minimal:

```powershell
Start-ThreadJob -ScriptBlock {
    param($ModulePath, $P4Args, $RequestId, $Queue)
    Import-Module $ModulePath -Force
    try {
        $result = Invoke-P4 -P4Args $P4Args
        $Queue.Enqueue([pscustomobject]@{
            RequestId = $RequestId
            Kind      = 'Complete'
            Result    = $result
            Succeeded = $true
        })
    } catch {
        $Queue.Enqueue([pscustomobject]@{
            RequestId = $RequestId
            Kind      = 'Failed'
            ErrorText = $_.Exception.Message
            Succeeded = $false
        })
    }
} -ArgumentList $modulePath, $p4Args, $requestId, $script:CompletionQueue
```

### D5: Observer pattern adaptation

The current single-slot `$script:P4ExecutionObserver` is module-scoped and works within one runspace. For background execution:

- The background scriptblock captures its own observer data internally
- On completion, the observer events are sent back via the `ConcurrentQueue` as part of the result payload
- The main loop dispatches `LogCommandExecution` actions as before

## Scope

### 4.1 Introduce `Runtime.ActiveCommand` state

Add a runtime model for the active command:

```powershell
Runtime.ActiveCommand = [pscustomobject]@{
    RequestId       = [string]   # monotonic ID for stale-result matching
    Kind            = [string]   # e.g. 'LoadFiles', 'ReloadPending', 'Describe'
    CommandLine     = [string]   # display string
    StartedAt       = [datetime]
    Status          = [string]   # 'Running' | 'Cancelling'
    CancelRequested = [bool]
    JobId           = [int]      # Start-ThreadJob ID for cleanup
    ProcessId       = [int]      # when available, for cancel/kill
}
```

When `ActiveCommand` is non-null, the main loop renders the busy modal with live elapsed time (since the main loop is now free), and polls input normally.

### 4.2 Refactor `Invoke-BrowserSideEffect` into async dispatch

Replace the synchronous `Invoke-BrowserSideEffect` with an async variant:

**New flow:**

1. Reducer emits `PendingRequest` (unchanged)
2. Main loop calls `Start-BrowserCommand` which:
   - Dispatches `CommandStart` action
   - Starts a `Start-ThreadJob` with the work scriptblock
   - Sets `Runtime.ActiveCommand`
3. Main loop continues rendering and polling input
4. On each iteration, the main loop drains `$CompletionQueue`
5. On completion: dispatches `CommandComplete` (with result data) or `CommandFailed`
6. Reducer updates state, sets `ActiveCommand = $null`

**Backward compatibility:** For simple, fast commands, synchronous execution can remain as an optimization. Only commands expected to be slow need background dispatch.

### 4.3 Keep the main loop alive while commands run

While `ActiveCommand` is non-null, the main loop supports:

- Live elapsed-time display in the busy modal
- Resize handling
- Command log navigation (if overlay mode permits)
- `Escape` → cancel request
- `Q` → deferred quit

General browsing (screen switching, filtering) while a command runs is **deferred** — it introduces state conflicts that need careful analysis. The modal stays open and blocks navigation while a command is active.

### 4.4 Add stale-result protection

Background results must only apply if still relevant. Use `RequestId` matching:

```powershell
# In reducer, on CommandComplete:
if ($action.RequestId -ne $state.Runtime.ActiveCommand.RequestId) {
    # Stale result — discard silently
    return $state
}
```

Scenarios where results become stale:

- User switched screens while a command was running
- User triggered a reload that superseded the previous request
- User navigated to a different changelist

### 4.5 Add elapsed-time display to the busy modal

With the main loop alive during background execution, the busy modal can now update dynamically:

```powershell
# In Build-CommandModalRows, when IsBusy:
$elapsed = (Get-Date) - $CommandModal.StartedAt
$elapsedText = '{0:0.0}s' -f $elapsed.TotalSeconds
# "[⏳] Running 8.4s: p4 fstat ..."
```

The render cycle runs every 50 ms (the input poll interval), providing smooth timer updates.

### 4.6 Preserve command-log behavior

The command observer events captured by the background thread are delivered via `ConcurrentQueue` and dispatched as `LogCommandExecution` actions on the main thread. The existing command log, modal history, and command output screens continue to work.

### 4.7 Error boundary design

Background thread failures must be surfaced cleanly:

| Failure type | Handling |
|---|---|
| `Invoke-P4` throws (timeout, process failure, p4 error) | `ConcurrentQueue` receives `Failed` event; reducer shows error in modal |
| Thread job crashes (unhandled exception) | Main loop polls job state; on `Failed` state, extracts error and dispatches `CommandFailed` |
| Thread job hangs | Watchdog timer; if `ActiveCommand` exceeds `2 × TimeoutMs`, kill job and report timeout |
| Module import fails in background | `catch` in background scriptblock enqueues error event |

### 4.8 Dependency Injection for testability

The background execution layer should be injectable for Pester tests:

```powershell
# Production: uses Start-ThreadJob
$script:CommandExecutor = {
    param($ScriptBlock, $ArgumentList)
    Start-ThreadJob -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
}

# Test: executes synchronously, returns a mock job
$script:CommandExecutor = {
    param($ScriptBlock, $ArgumentList)
    # Execute inline and return result object
    ...
}
```

This allows testing the full dispatch→complete→reduce cycle without actual background threads or p4 connections.

## Files Touched

- `PerfourceCommanderConsole.psm1` — `Start-BrowserCommand`, completion queue draining, main loop restructuring
- `p4/P4Cli.psm1` — thread-safe observer data collection
- `tui/Reducer.psm1` — `ActiveCommand` state, `CommandComplete`/`CommandFailed` actions, stale-result check, `Copy-BrowserState` update
- `tui/Render.psm1` — live elapsed-time display, cancel-hint in footer
- `tests/Reducer.Tests.ps1` — active command lifecycle, stale-result dropping
- `tests/P4Cli.Tests.ps1` — observer data collection in isolation

## Acceptance Criteria

- The TUI remains responsive during long-running `p4` commands.
- Elapsed time updates live in the busy modal.
- Active command state is visible and testable.
- Background results are applied safely or discarded when stale.
- Command log still captures execution details.
- Error paths are covered (timeout, crash, stale).
- DI seam allows Pester tests without background threads.

## Pros

- Biggest UX improvement in the plan
- Unlocks true cancellation and richer command UX
- Main loop stays simple: render → poll → drain completions → reducer

## Cons

- Largest implementation cost
- Cross-thread concerns require careful handling
- Module import overhead per thread job (~50–100 ms)
- `Copy-BrowserState` must handle `ActiveCommand` correctly

---

# Milestone 5 — True Cancellation and Polished Long-Running Command UX

## Objective

Complete the transition to a robust, modern command UX with true process cancellation and clear outcome semantics.

## Scope

### 5.1 Implement true cancel

When a background command is active:

1. User presses `Escape`
2. Reducer sets `ActiveCommand.CancelRequested = $true`, `Status = 'Cancelling'`
3. Main loop detects the cancellation request and:
   - Calls `Stop-Job` on the thread job
   - If the process ID is available, calls `taskkill /F /T /PID` (reusing existing `Invoke-P4` timeout logic)
4. Background thread's `catch` block enqueues a `Cancelled` event
5. Reducer receives it, sets `ActiveCommand = $null`, shows `[CANCEL]` in modal

**Process ID availability:** The background scriptblock needs to pass the `Process.Id` back to the main thread early. Use an additional `ConcurrentQueue` or an `[int]` boxed in a shared reference:

```powershell
$pidHolder = [System.Collections.Concurrent.ConcurrentQueue[int]]::new()
# Background thread enqueues PID after process.Start()
# Main thread dequeues PID for cancel/kill
```

### 5.2 Distinguish cancel from timeout and failure

User-facing outcomes should be clearly separated:

| Outcome | Tag | Color | Meaning |
|---|---|---|---|
| Completed | `[OK]` | Green | Command succeeded |
| Failed | `[ERR]` | Red | Command returned error |
| Timed out | `[TIMEOUT]` | DarkYellow | Process killed after timeout |
| Cancelled | `[CANCEL]` | Cyan | User-initiated cancellation |

The reducer should set a `CompletionKind` field on history entries rather than relying solely on `Succeeded` boolean.

### 5.3 Consistent command lifecycle states

All commands pass through a well-defined state machine:

```
Queued → Running → Completed
                 → Failed
                 → Cancelling → Cancelled
                 → TimedOut
```

The modal and command log should reflect these states consistently.

### 5.4 Browse command history while another command runs

Since M4 keeps the main loop alive, allow limited navigation:

- `F12` toggles the command modal (already exists)
- Arrow keys scroll command history within the modal
- `Enter` on a command entry opens the command output screen

General screen navigation (switching changelists, opening files) while a command runs remains blocked to avoid state conflicts.

### 5.5 Future: Speculative pre-fetching

After the background execution model is stable, consider **speculative execution**:

When a user highlights a changelist for > 500 ms without pressing Enter, start a background `Start-ThreadJob` that pre-fetches file metadata:

```powershell
# Speculative pre-fetch on hover
$prefetchJob = Start-ThreadJob {
    param($ModulePath, $Change, $Cache, $Queue)
    Import-Module $ModulePath -Force
    $files = @(Get-P4OpenedFiles -Change $Change)
    $Queue.Enqueue(@{
        Kind = 'PrefetchComplete'
        Change = $Change
        Files = $files
    })
} -ArgumentList ...
```

If the user presses Enter, the files screen paints instantly from the pre-fetched cache. If they move away, the result is simply discarded (stale-result protection from M4 handles this automatically).

**Design rules for speculative execution:**

- Only pre-fetch read-only data (never mutating operations)
- Limit to one active pre-fetch at a time
- Use a debounce interval to avoid thrashing
- Pre-fetched data enters the same `FileCache` as regular loads

### 5.6 Future: Parallel enrichment pipeline

With the background execution infrastructure in place, multiple independent enrichment calls could run concurrently as separate thread jobs:

```
ThreadJob A: Get-P4OpenedFileCounts
ThreadJob B: Get-P4ShelvedFileCounts     } run concurrently
ThreadJob C: Get-P4UnresolvedFileCounts
```

Each job enqueues its result; the reducer merges them into the changelist entries as they arrive. This provides progressive enrichment — the user sees counts appear as each query completes.

## Acceptance Criteria

- The user can explicitly cancel a running command.
- Cancelled commands are reported distinctly from failures and timeouts.
- UI states for long-running commands are consistent.
- The app no longer requires closing the window to escape a bad wait state.

## Pros

- Fully solves the original pain point
- Professional, polished TUI experience
- Foundation for speculative and parallel workflows

## Cons

- Process-kill coordination across threads requires careful lifecycle management
- Command output screen must handle partial/cancelled output
- Speculative pre-fetching adds complexity to cache management

---

## Cross-Cutting Design Rules

These rules apply throughout the plan.

### Rule 1: Preserve correctness over cleverness

If a metadata source is slow, it is acceptable to delay or omit it temporarily. It is not acceptable to show incorrect data without making that clear.

### Rule 2: Favor first paint over full enrichment

For browsing workflows, a quick usable screen is better than a fully enriched but delayed screen.

### Rule 3: Distinguish state clearly

Users should be able to tell the difference between:

- idle
- loading
- partially loaded
- cancel requested
- cancelled
- failed
- timed out

### Rule 4: Treat stale results as normal

Once commands run in the background, stale completions are expected. Handling them safely should be part of the design, not an afterthought.

### Rule 5: Keep the reducer authoritative

Even when background work is introduced, state transitions should still flow back through reducer actions rather than being mutated ad hoc. The `ConcurrentQueue` → reducer dispatch pattern preserves this contract.

### Rule 6: No concurrent console writes

Only the main thread writes to `[Console]`. Background threads communicate exclusively via the `ConcurrentQueue`. This avoids corruption from constraint C2.

### Rule 7: Injectable execution for testability

Use Dependency Injection (DI) for the command executor so Pester tests can exercise the full dispatch→complete→reduce cycle synchronously, without background threads or p4 connections.

---

## Testing Strategy

### General principles (from Agents.md)

- Run Pester in a fresh `pwsh -NoProfile` process
- Use DI to make testing independent of p4 connections
- Test behavior and contracts, not arbitrary literals
- Normalize 0..N results at call boundaries with `@(...)`

### Unit tests

| Area | Tests |
|---|---|
| Threshold classification | `LogCommandExecution` correctly tags slow/warning/critical |
| Timeout category resolution | `Get-P4TimeoutForArgs` returns correct timeout per subcommand |
| Busy modal rendering | `Build-CommandModalRows` shows correct content for busy/idle/cancel states |
| Elapsed-time formatting | Duration formatted correctly for display |
| Enrichment state transitions | Cache entry transitions: Pending → Loading → Complete/Failed |
| Deferred quit | `QuitRequested` flag set by Quit action, respected by main loop |
| Cancel-request state | `CancelRequested` set by RequestCancel, blocks further workflow items |
| Active command lifecycle | `CommandStart` → `CommandComplete` (or `Failed`/`Cancelled`) transitions |
| Stale-result dropping | Completion with mismatched `RequestId` is silently discarded |
| Phased file loading | Files loaded without enrichment; enrichment added later |
| Copy-BrowserState | `ActiveCommand` deep-copied correctly |

### Integration tests

| Scenario | Validates |
|---|---|
| Open files screen: first paint fast, enrichment deferred | M2 phased loading |
| Workflow cancel between items | M3 checkpoint cancellation |
| Deferred quit during long operation | M3 quit semantics |
| Background command completes normally | M4 full lifecycle |
| Stale result ignored after navigation change | M4 stale-result protection |
| Command log populated for background commands | M4 observer integration |
| True cancel terminates running command | M5 cancel lifecycle |
| Cancelled vs failed vs timed-out distinction | M5 outcome semantics |

### Failure-path tests

| Scenario | Validates |
|---|---|
| Process timeout and kill | `Invoke-P4` timeout handling (existing + category-aware) |
| Kill failure fallback (`Process.Kill()`) | Robust cleanup even when `taskkill` fails |
| Background thread crash | Error surfaced via `ConcurrentQueue`, shown in modal |
| Module import failure in thread job | Error enqueued, main thread handles gracefully |
| Observer cleanup on error | No leaked observers after exceptions |
| Job watchdog timeout | Hung jobs detected and cleaned up |
| Concurrent cancel + timeout race | Whichever arrives first wins; no duplicate transitions |

### DI mocks for command execution

```powershell
# Mock executor for Pester tests:
$mockExecutor = {
    param($ScriptBlock, $ArgumentList)
    # Run synchronously, return a completed-job-like object
    $result = try { & $ScriptBlock @ArgumentList } catch { $_ }
    [pscustomobject]@{
        Id    = 1
        State = 'Completed'
        Output = $result
    }
}
```

This allows testing the orchestration layer (dispatch, drain, reduce) without actual thread jobs.

---

## Recommended Delivery Order

### Release A

Ship Milestone 1 and the most valuable parts of Milestone 2:

- Threshold instrumentation and constants
- Improved busy modal copy (static, with timeout info)
- Color-coded command log durations
- Category-aware timeouts
- Split file loading from `p4 diff -sa` enrichment
- Enrichment state model in file cache
- Visual indicators for pending enrichment

### Release B

Ship Milestone 3:

- Cancel-request flag and inter-step checking
- Deferred quit
- Input polling between workflow steps
- Step-progress in modal footer

### Release C

Ship Milestone 4:

- `ConcurrentQueue`-based completion channel
- `Start-ThreadJob` execution
- `ActiveCommand` runtime state
- Live elapsed-time display
- Stale-result protection
- DI seam for testing

### Release D

Ship Milestone 5:

- True process cancellation via PID
- Distinct cancelled/timed-out/failed outcomes
- Command lifecycle state machine
- Command history browsing while running

---

## Recommended First Implementation Slice

If work must start immediately, the best first slice (producing visible value quickly) is:

1. Add `$CommandThresholds` constants and color-code duration in command log
2. Improve busy modal footer to show timeout info
3. Split file loading from `p4 diff -sa` enrichment — two-phase `PendingRequest`
4. Add enrichment-status model to file cache
5. Add deferred-quit flag (`QuitRequested`)

This touches few files, has minimal risk, and produces measurable improvement.

---

## Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| `Start-ThreadJob` module import overhead (~50–100 ms per job) | Background commands start slower | Pool/cache the runspace, or accept the overhead for long-running commands |
| Console corruption from concurrent writes | Garbled output | Rule 6: only main thread writes to Console |
| Stale results applied after navigation | Wrong data displayed | RequestId matching (M4.4) with silent discard |
| Observer pattern doesn't work across runspaces | Missing command log entries | Background thread captures observer data locally, sends via queue |
| `ConcurrentQueue` memory growth | Unbounded queue | Drain every 50 ms iteration; queue depth is naturally bounded by command rate |
| Race between cancel and completion | Duplicate state transitions | Reducer ignores transitions when `ActiveCommand` is `$null` |
| Module state pollution between thread jobs | Stale module-scoped state | Each thread job imports fresh; `-Force` flag on `Import-Module` |

---

## Deliverables Checklist

### Milestone 1

- [ ] `$CommandThresholds` constants added to `P4Cli.psm1`
- [ ] `$P4TimeoutByCategory` with per-subcommand timeouts
- [ ] `Get-P4TimeoutForArgs` function
- [ ] Busy modal shows timeout info and UTF-8 status glyph
- [ ] Command history rows color-coded by duration threshold
- [ ] `[TIMEOUT]` tag distinct from `[ERR]`
- [ ] Tests for threshold classification and timeout resolution

### Milestone 2

- [ ] `Invoke-BrowserFilesLoad` split into fast + enrichment phases
- [ ] `EnrichFiles` pending request kind added
- [ ] File cache entries carry `EnrichmentStatus`
- [ ] Enrichment triggers only when needed (demand-driven)
- [ ] UI shows `…` for pending enrichment, `✗` for failed
- [ ] Tests cover phased loading and enrichment state transitions

### Milestone 3

- [ ] `Runtime.CancelRequested` flag
- [ ] `Runtime.QuitRequested` flag
- [ ] Input polling between workflow items
- [ ] `RequestCancel` action and reducer handler
- [ ] Modal footer reflects cancel/quit intent and step progress
- [ ] Tests for cancel and quit state transitions

### Milestone 4

- [ ] `ConcurrentQueue`-based completion channel
- [ ] `Start-BrowserCommand` with `Start-ThreadJob`
- [ ] `Runtime.ActiveCommand` state model
- [ ] Main loop drains completions and dispatches actions
- [ ] Live elapsed-time display in busy modal
- [ ] Stale-result protection via `RequestId`
- [ ] Error boundary for thread crashes / import failures
- [ ] DI seam for command executor
- [ ] Observer events delivered via queue
- [ ] `Copy-BrowserState` handles `ActiveCommand`
- [ ] Tests for full async lifecycle and error paths

### Milestone 5

- [ ] True cancel via PID + `taskkill`
- [ ] `Cancelled` outcome distinct from `Failed` / `TimedOut`
- [ ] Command lifecycle state machine visible in modal
- [ ] Command history navigation while command runs
- [ ] Tests for cancel lifecycle and race conditions
