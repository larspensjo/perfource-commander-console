# Plan: Command Log View (Mode '3')

Replace the F12 modal with a first-class view mode for inspecting p4 command history. Mode '3' reuses the existing `ViewMode` pattern (`'Pending'`/`'Submitted'`/`'CommandLog'`), rendering commands in the top-right pane with status+command-type filters in the left pane. Right arrow pushes a `'CommandOutput'` screen (like `'Files'`) for scrollable pretty-printed output. The auto-popup modal during command execution is kept unchanged.

## Steps

### 1. Capture command output — Event Queue Bridge

A single user action (and its `WorkItem`) often executes *multiple* `p4` commands under the hood (e.g., `p4 changes` + `p4 opened` + batched `p4 describe`). Use an **observer + event queue bridge** so every individual `Invoke-P4` call is logged accurately while keeping the reducer as the single state mutation path.

#### 1a. Observer hook in `p4/P4Cli.psm1`

Add a module-scoped observer variable:

```powershell
[scriptblock]$script:P4ExecutionObserver = $null
```

At the end of `Invoke-P4`, after capturing stdout/stderr and computing the exit code, invoke the observer if present. Observer invocation **must be wrapped in try/catch** so logging never breaks p4 operations:

```powershell
if ($script:P4ExecutionObserver) {
    try {
        & $script:P4ExecutionObserver -CommandLine $commandLine -RawLines $rawLines `
            -ExitCode $exitCode -ErrorOutput $stderr `
            -StartedAt $startedAt -EndedAt $endedAt -DurationMs $durationMs
    } catch { <# observer must not break p4 operations #> }
}
```

Expose `Register-P4Observer` / `Unregister-P4Observer` functions for clean setup and teardown.

#### 1b. Pretty-printer: `Format-P4OutputLine`

Add a generic pretty-printer in `p4/P4Cli.psm1` that condenses each JSON object into a human-readable single line (e.g., `"CL#12345 – Fix build (user@ws)"`). Include a **safe fallback** that converts unrecognized objects to their string/JSON representation, so unexpected p4 output never causes errors.

Processing pipeline (applied eagerly before storage):
1. Parse/normalize raw lines defensively.
2. Generate pretty lines with fallback for unknown shapes.
3. Cap to `$script:CommandOutputMaxLines` (named constant, default 2000).
4. Record `OutputCount` (uncapped total) alongside `FormattedLines` (capped).

#### 1c. Event queue wiring in `PerfourceCommanderConsole.psm1`

Use an explicit **event queue bridge** to keep reducer as the single state mutation path:

1. Before executing a side-effect `WorkItem`, create a temporary event queue (e.g., `[System.Collections.Generic.List[pscustomobject]]`).
2. Register a `P4ExecutionObserver` that pretty-prints the output and **appends** an immutable event object to the queue (containing `CommandLine`, `FormattedLines`, `OutputCount`, `SummaryLine`, `ExitCode`, `ErrorText`, `StartedAt`, `EndedAt`, `DurationMs`).
3. Execute the `WorkItem`.
4. In a `finally` block, **unregister** the observer.
5. After the `WorkItem` completes, dispatch a `LogCommandExecution` action **for each queued event** to the reducer.

This ensures every actual p4 command is accurately logged with its own output, the reducer remains the single state mutation path, and observer lifetime is scoped to the side-effect block.

The existing `Invoke-BrowserSideEffect` / `CommandStart` / `CommandFinish` lifecycle for the auto-popup modal remains unchanged — it tracks the high-level *user action*, while `LogCommandExecution` tracks each *individual p4 call*.

### 2. Extend state

In `New-BrowserState` (`tui/Reducer.psm1`):

**Identity:**
- Add `Runtime.NextCommandId` — monotonic `[int]` counter (starts at 1). Each `LogCommandExecution` assigns the next ID.

**Command log metadata** (lightweight, safe to deep-copy):
- Add `Runtime.CommandLog` — array of command-log metadata items, newest-first, each containing:
  - `CommandId` (string) — stable, monotonic identifier
  - `StartedAt`, `EndedAt` (datetime)
  - `CommandLine` (string)
  - `ExitCode` (int), `Succeeded` (bool), `ErrorText` (string)
  - `DurationMs` (int)
  - `OutputCount` (int) — total entry count before truncation
  - `SummaryLine` (string)
  - `OutputRef` (string) — key into `CommandOutputCache`

Capped at `$script:CommandLogMaxSize` (named constant, default 200).

**Heavy output cache** (shared dictionary, not deep-copied — mirrors `FileCache`/`DescribeCache` pattern):
- Add `Data.CommandOutputCache` — `@{}` mapping `CommandId` → `string[]` (formatted lines). Evict entries when their metadata is trimmed from `CommandLog`.

**UI state:**
- Add `Ui.ExpandedCommands` — `HashSet[string]` of CommandIds (use `[string]` because `Copy-StateObject` already handles `HashSet[string]` correctly; `HashSet[int]` would be shared by reference).
- Add `Runtime.CommandOutputCommandId` — the CommandId whose output is being viewed on the pushed output screen.

**Cursors:**
- Add `Cursor.CommandIndex`, `Cursor.CommandScrollTop` (for the command list pane).
- Add `Cursor.OutputIndex`, `Cursor.OutputScrollTop` (for the pushed output screen).
- Add `Cursor.ViewSnapshots.CommandLog` entry for cursor save/restore.

Note: `Runtime.CommandLog` is separate from `Runtime.ModalPrompt.History`. The modal history tracks high-level side-effect lifecycle (one entry per `WorkItem`); `CommandLog` tracks individual p4 invocations (one entry per `Invoke-P4` call).

### 3. Extend reducer — `LogCommandExecution` action

Add a `LogCommandExecution` handler in the reducer:
- Assign `Runtime.NextCommandId` as `CommandId` (convert to string); increment counter.
- Create metadata item (without `FormattedLines`); store `OutputRef = CommandId`.
- Store formatted lines in `Data.CommandOutputCache[CommandId]`.
- Prepend metadata to `Runtime.CommandLog`.
- If array exceeds `$script:CommandLogMaxSize`, trim oldest entries and **evict corresponding keys** from `CommandOutputCache`.
- This is a pure state update — no I/O.

### 4. Extend reducer — ViewMode 'CommandLog'

In `Invoke-ChangelistReducer` (`tui/Reducer.psm1`), extend the `SwitchView` case to accept `'CommandLog'`. Add `'CommandLog'` to any `ValidateSet` declarations that currently restrict to `'Pending'`/`'Submitted'`. Save/restore cursor snapshots as done for Pending/Submitted. When entering CommandLog, skip filter/reload logic (command history is already in state).

### 5. Extend reducer — CommandLog actions

Keep input mapping static (approach A from review) — the **reducers** interpret actions by the active `ViewMode`/`ScreenStack`, not the input layer. This follows the existing router pattern and avoids coupling input to state.

Add command-log-aware branches to existing action handlers in `Invoke-ChangelistReducer`:

- `MoveUp`/`MoveDown`/`PageUp`/`PageDown`/`MoveHome`/`MoveEnd` — when `ViewMode -eq 'CommandLog'` and `ActivePane -eq 'Changelists'`, navigate `Cursor.CommandIndex` (reuse existing scroll-clamping helpers). Note: use existing action names `MoveHome`/`MoveEnd`, not `Home`/`End`.
- `ToggleChangelistView` (`E` key) — when `ViewMode -eq 'CommandLog'`, toggle the selected command's `CommandId` in `Ui.ExpandedCommands`. When expanded, the row shows an extra summary line below the command.
- `OpenFilesScreen` (right arrow / `O` key) — when `ViewMode -eq 'CommandLog'`, push `'CommandOutput'` onto `Ui.ScreenStack` and store the selected `CommandId` in `Runtime.CommandOutputCommandId`.
- F12 dispatches `SwitchView CommandLog` from any changelist-level screen. If already on a pushed screen (`Files`/`CommandOutput`), pop back first, then switch.

### 6. Add CommandOutput screen reducer

Create `Invoke-CommandOutputReducer` handling `MoveUp`/`MoveDown`/`PageUp`/`PageDown`/`MoveHome`/`MoveEnd` for scrolling through formatted output lines, and `Escape`/left-arrow to pop the screen. In `Invoke-BrowserReducer` (`tui/Reducer.psm1`), route to this reducer when `ScreenStack[-1] -eq 'CommandOutput'`. This keeps screen logic isolated in its own reducer function, mirroring the `Invoke-FilesReducer` pattern.

### 7. Add derived state for CommandLog

In `Update-BrowserDerivedState` (`tui/Reducer.psm1`), when `ViewMode -eq 'CommandLog'`:

- Compute `Derived.VisibleCommandIds` by applying selected filters (status OK/Error, command type) to `Runtime.CommandLog`. Result is an array of `CommandId` strings in **display order** (oldest first — reverse of storage order).
- Compute `Derived.VisibleCommandFilters` with match counts, same shape as existing `VisibleFilters`.
- Clamp `Cursor.CommandIndex` to the visible list length.

### 8. Add CommandLog filters

In `tui/Filtering.psm1`, add `Get-CommandLogFilterPredicates` returning:

- **Status group**: `OK`, `Error` (keyed on `Succeeded`).
- **Command-type group**: one filter per unique p4 subcommand extracted from `CommandLine` (e.g., `changes`, `describe`, `opened`, `files`, `shelve`, `info`). Use a regex like `p4\s+(\S+)` to extract the subcommand. Include a fallback for unrecognized command lines.

Update `ValidateSet` and branching in related functions (`Get-AllFilterNames`, `Test-EntryMatchesFilter`, or equivalents) to support `'CommandLog'` view mode.

### 9. Input mapping

In `ConvertFrom-KeyInfoToAction` (`tui/Input.psm1`):

- `'D3'` → `@{ Type = 'SwitchView'; View = 'CommandLog' }`.
- `'F12'` → `@{ Type = 'SwitchView'; View = 'CommandLog' }` (replaces `ToggleCommandModal`).

All other keys (`E`, right-arrow, `MoveHome`/`MoveEnd`, etc.) keep their **existing static action mappings**. The reducers interpret actions differently based on `ViewMode`/`ScreenStack` context (approach A). This preserves the simple, stateless input layer.

### 10. Render command list

In `tui/Render.psm1`, add `Build-CommandLogRows` (mirroring `Build-ChangelistRows`):

- One row per command: `HH:mm:ss  [OK]  1234ms  p4 changes -s pending -m 200` (with color: green for OK, red for Error, yellow for Running).
- If expanded (via 'E'): an indented summary row below: `  └─ 200 entries` or `  └─ Error: connection refused`.
- Highlight the selected row (using `CommandId` to identify selection, not index).
- Display order: oldest at top (driven by `Derived.VisibleCommandIds`).

### 11. Render command detail pane

When `ViewMode -eq 'CommandLog'`, the bottom-right detail pane shows full details of the selected command: command line, start/end timestamps, duration, exit code, error text (if any), and a preview of the first ~10 output lines (fetched from `Data.CommandOutputCache` via `OutputRef`). This gives a quick glance without needing to push the output screen.

### 12. Render CommandOutput screen

Add `Build-CommandOutputFrame` (mirroring `Build-FilesScreenFrame`):

- Title: `[Output: p4 changes -s pending ...]`.
- Left pane: blank for V1 (output filters are a future extension).
- Right pane: scrollable list of formatted output lines (from `Data.CommandOutputCache[Runtime.CommandOutputCommandId]`).
- Status bar: `[← Back]  Line X of Y`.

### 13. Update frame builder routing

In `Build-FrameFromState` (`tui/Render.psm1`), when `ViewMode -eq 'CommandLog'`, call `Build-CommandLogRows` instead of `Build-ChangelistRows` for the list pane. Similarly, call command detail rendering for the detail pane. In `Render-BrowserState`, route `ScreenStack[-1] -eq 'CommandOutput'` to `Build-CommandOutputFrame`.

### 14. Update status bar

In the status bar builder (`tui/Render.psm1`), add a `[Commands]` badge when `ViewMode -eq 'CommandLog'`. Show `[1] Pending  [2] Submitted  [3] Commands` as mode indicators (highlight active).

### 15. Update help overlay

Add documentation for '3' key and 'E' expand in the help text.

### 16. Tests

#### Unit tests (must-have)

**`tests/P4Cli.Tests.ps1`:**
- Observer register/unregister behavior
- Observer called on success with correct parameters
- Observer called on non-zero exit path
- Observer exception does not break `Invoke-P4`
- Observer cleanup in teardown blocks

**`tests/Reducer.Tests.ps1`:**
- `SwitchView` accepts `CommandLog` and restores snapshots
- `LogCommandExecution` prepend, ID assignment, trim + cache eviction
- Command-log navigation: `MoveUp`/`MoveDown`, `PageUp`/`PageDown`, `MoveHome`/`MoveEnd`
- `ToggleChangelistView` toggles expand by `CommandId` (not index) in CommandLog mode
- Open output screen + back navigation via `CommandId`
- Unchanged behavior for Pending/Submitted and Files screen

**`tests/Filtering.Tests.ps1`:**
- Command status filters (`OK`, `Error`)
- Command-type extraction + filtering
- Fallback handling for unrecognized command lines

**`tests/Input.Tests.ps1`:**
- `D3` → `SwitchView CommandLog`
- `F12` → `SwitchView CommandLog`

**`tests/Render.Tests.ps1`:**
- Command row format and color tags
- Expanded summary row
- Command detail pane content
- Output screen status bar line counters
- Status bar mode indicator includes mode 3
- Help overlay updated key text

#### Integration tests (high-value)

Add reducer-level "journey" tests:
1. Start in Pending → switch to CommandLog → open output → back → switch to Submitted
2. Command log receives new item while viewing output screen (CommandId stable)
3. Trim behavior evicts old outputs from `CommandOutputCache` safely
4. Expanded commands remain attached to correct `CommandId` after new entries arrive

## Verification

- Run linter: `pwsh -NoProfile -File .vscode/Invoke-Linter.ps1`
- Run full test suite: `pwsh -NoProfile -Command "Import-Module Pester -Force; Invoke-Pester -Path tests\"`
- Manual testing:
  - Launch TUI, press '3' — verify command list shows (initially empty or with startup commands)
  - Trigger p4 operations via '1'/'2', switch back to '3' — verify commands appear oldest-first
  - Press 'E' to expand — verify summary lines appear attached to the correct commands
  - Right-arrow to view output, left-arrow/Escape to return
  - Verify F12 switches to mode '3' from any changelist-level screen
  - Verify auto-popup modal still appears during command execution
  - Verify command IDs remain stable when new entries arrive
  - Verify expanded rows remain attached to correct command after inserts
  - Verify no perceptible UI lag with 200 history entries and capped output

## Decisions

- **ViewMode pattern** (not ScreenStack) for mode '3' — consistent with '1'/'2'.
- **Stable monotonic `CommandId`** (string) for identity — indices drift as new commands arrive and filters change. `HashSet[string]` used because `Copy-StateObject` already handles it correctly.
- **Separate heavy output from light metadata** — `Data.CommandOutputCache` (shared dictionary, not deep-copied) vs `Runtime.CommandLog` (lightweight metadata, safe to copy). Mirrors the existing `FileCache`/`DescribeCache` pattern. Avoids severe CPU/memory churn from copying 2000-line arrays on every keystroke.
- **Event queue bridge** for observer → reducer — observer appends to a queue during `WorkItem` execution; events are dispatched to the reducer afterward. Keeps reducer as single state mutation path and scopes observer lifetime to the side-effect block.
- **Static input mapping, context-aware reducers** (approach A) — `ConvertFrom-KeyInfoToAction` remains stateless. Reducers interpret `E`, right-arrow, etc. differently based on `ViewMode`/`ScreenStack`. Follows existing router pattern.
- **Named constants** for all caps/sizes — `$script:CommandLogMaxSize`, `$script:CommandOutputMaxLines`. No naked constants.
- **Pretty-print + cap at 2000 lines** — balances usability and memory. Cap applied before storing to avoid large intermediate allocations.
- **Command Observer pattern** in P4Cli — each `Invoke-P4` call notifies the observer with its own output, solving the multiple-commands-per-WorkItem problem. Observer exceptions are caught and non-fatal.
- **Separate `Runtime.CommandLog`** from `Runtime.ModalPrompt.History` — modal history tracks high-level user actions; command log tracks individual p4 invocations.
- **F12 → SwitchView CommandLog** — single mental model for command inspection. Applies from any changelist-level screen; pops pushed screens first if needed.
- **Status + command-type filters** in left pane — reuses existing filter infrastructure. `ValidateSet` and filter contracts extended for `'CommandLog'`.
- **CommandOutput as pushed screen** — consistent with the existing Files screen pattern. Isolated reducer (`Invoke-CommandOutputReducer`).

## Future Ideas

### Near-term
- **Search/filter within output**: Add `/` key in the CommandOutput screen to filter output lines by text, mirroring the file filter pattern.
- **Copy to clipboard**: `C` key on a command to copy the command line, or in the output screen to copy all output — useful for bug reports.
- **Quick jump to latest failed command**: Shortcut key in CommandLog mode.

### Mid-term
- **Auto-scroll to newest**: When a new command completes and you're in mode '3', optionally scroll to the bottom (newest) — could be a toggle.
- **Re-run command**: `R` key to re-execute the selected command and refresh its output.
- **Correlate commands to work items**: Add `WorkItemId` linking individual p4 calls to the high-level side-effect that triggered them.
- **Aggregate metrics panel**: p95 duration by subcommand.
- **Export command log as JSON**: For diagnostics and bug reports.

### Long-term
- **Trace mode for debugging**: An option to dump the raw JSON from p4 instead of using the pretty-printer — invaluable for debugging unexpected behavior.
- **Execution timeline/Gantt**: Visualize sequential bottlenecks across commands to spot performance issues.
- **Diff between repeated command outputs**: Compare results of the same command at different times.
- **Privacy redaction pipeline**: Before persistence/export.
