# PerFourceCommanderConsole — Next Step: Command Output Modal (p4 command visibility)

Goal: add a transient **modal output window** that shows the **exact p4 command line** being executed.

This plan follows the chosen UX:
- Auto-open for **all** p4 commands (including startup load)
- Modal while command is running (no other interaction)
- Auto-close on success; **stays open on failure** until dismissed with `Esc`
- User can manually reopen a **rolling command history**
- Show **exact command line only** (no stdout/stderr streaming)

---

## Design constraints

- Keep **unidirectional data flow**:
  - reducer remains pure (state transitions only)
  - p4 process I/O remains outside reducer
- Keep the implementation incremental and test-first.
- Avoid large layout refactors: implement as an overlay/modal, not a permanent pane.

---

## Overview of edits

| File | Change |
|------|--------|
| `p4/P4Cli.psm1` | Extract `Format-P4CommandLine` helper; no callback hook |
| `tui/Reducer.psm1` | Add command-modal state + actions; move `Reload` I/O out of reducer |
| `tui/Input.psm1` | Add `F6` / `Esc` key bindings |
| `tui/Render.psm1` | Render modal overlay when visible |
| `PerfourceCommanderConsole.psm1` | Explicit `CommandStart`/`CommandFinish` dispatch around each p4 I/O block; extract `Invoke-BrowserSideEffect` helper |
| `tests/P4Cli.Tests.ps1` | Add `Format-P4CommandLine` tests |
| `tests/Reducer.Tests.ps1` | Add reducer/action tests for modal/history |
| `tests/Render.Tests.ps1` | Add rendering tests for overlay visibility/content |

---

## 1) Data model changes (state)

### 1.1 Add command-output state under `Runtime`

In `New-BrowserState` and `Copy-BrowserState` add:

- `Runtime.CommandModal = [pscustomobject]@{`
  - `IsOpen = $false`
  - `IsBusy = $false`
  - `CurrentCommand = ''`
  - `History = @()`  # newest first
- `}`

`MaxHistory` is a **module-level constant** rather than runtime state, since it is never mutated by any action:

```powershell
$script:CommandHistoryMaxSize = 50
```

This avoids needlessly copying an immutable value on every `Copy-BrowserState` call.

### 1.2 History item shape

Each history entry:

```powershell
[pscustomobject]@{
  StartedAt   = [datetime]
  EndedAt     = [datetime]
  CommandLine = 'p4 ...'
  ExitCode    = 0
  Succeeded   = $true
  ErrorText   = ''      # populated on failure; useful for future diagnostics
  DurationMs  = 0       # EndedAt - StartedAt in milliseconds
}
```

---

## 2) Action model additions (reducer-level)

Add reducer action types:

- `CommandStart`
  Payload: `CommandLine`, `StartedAt`
- `CommandFinish`
  Payload: `CommandLine`, `EndedAt`, `ExitCode`, `Succeeded`, `ErrorText`
- `ShowCommandModal`
  Manual reopen action
- `HideCommandModal`
  Used only when not busy (guarded)

Reducer behavior:

- `CommandStart`:
  - `IsBusy = $true`
  - `IsOpen = $true`
  - `CurrentCommand = <payload>`
- `CommandFinish`:
  - compute `DurationMs` = (`EndedAt` − `StartedAt`).TotalMilliseconds
  - prepend history item to `History`
  - trim to `$script:CommandHistoryMaxSize`
  - `IsBusy = $false`
  - `CurrentCommand = ''`
  - `IsOpen = $false` **only if `Succeeded`**; on failure keep open so the user sees the error
- `ShowCommandModal`:
  - `IsOpen = $true`
- `HideCommandModal`:
  - if `IsBusy` then no-op (guard against closing while command is running)
  - else `IsOpen = $false`

---

## 3) Input mapping

In `tui/Input.psm1` add key mappings:

- `F6` → `ShowCommandModal`
- `Escape` → `HideCommandModal`

Status bar text update in render:

- Add hint: `[F6] CmdLog`

---

## 4) P4 invocation instrumentation

### 4.1 Extract `Format-P4CommandLine` helper

The argument-quoting logic that already exists inside `Invoke-P4`:

```powershell
($P4Args | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
```

extract into an exported helper:

```powershell
function Format-P4CommandLine {
    param([Parameter(Mandatory)][string[]]$P4Args)
    $args = $P4Args | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
    return 'p4 ' + ($args -join ' ')
}
```

`Invoke-P4` is updated to call this helper internally (no duplicate logic). Existing callsites are unchanged.

### 4.2 Why no callback on `Invoke-P4`

`Invoke-P4` is synchronous: `ReadKey` is never called while a command is running, so modal blocking is **implicit** — no explicit focus-trapping or callback is needed. Adding an `OnCommandLifecycle` scriptblock would couple a low-level CLI wrapper to the TUI dispatch/render pipeline, violating separation of concerns. Instead, modal lifecycle is managed explicitly at each call site in the main loop (Section 5).

All existing callsites continue to work unchanged.

---

## 5) Main-loop orchestration

In `Start-P4Browser` (`PerfourceCommanderConsole.psm1`):

### 5.1 Explicit dispatch pattern

Rather than a callback, each logical p4 I/O block is wrapped with explicit reducer dispatches and an intermediate render call so the user sees the modal before the blocking call:

```powershell
$cmdLine = Format-P4CommandLine -P4Args @('describe', '-s', "$change")
$state = Invoke-BrowserReducer -State $state -Action @{ Type='CommandStart'; CommandLine=$cmdLine; StartedAt=Get-Date }
Render-BrowserState -State $state   # user sees modal before blocking I/O

$startedAt = Get-Date
try {
    $result   = Get-P4Describe -Change $change
    $exitCode = 0; $succeeded = $true; $errorText = ''
} catch {
    $exitCode = 1; $succeeded = $false; $errorText = $_.Exception.Message
}
$endedAt = Get-Date

$state = Invoke-BrowserReducer -State $state -Action @{
    Type='CommandFinish'; CommandLine=$cmdLine
    StartedAt=$startedAt; EndedAt=$endedAt
    ExitCode=$exitCode; Succeeded=$succeeded; ErrorText=$errorText
}
```

### 5.2 Extract `Invoke-BrowserSideEffect` helper

The describe, delete, reload, and initial-load blocks all follow the same structure (dispatch start → render → do I/O → dispatch finish → handle error). Extract a helper to avoid repetition (Agents.md: *Avoid repetition*):

```powershell
function Invoke-BrowserSideEffect {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$CommandLine,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    # dispatch CommandStart + render, then invoke $Action, then dispatch CommandFinish
    # returns updated $State
}
```

### 5.3 Move `Reload` I/O out of the reducer (required)

`Reload` currently performs I/O inside `Invoke-BrowserReducer`, violating reducer purity and bypassing the modal. This **must** be fixed in this iteration to satisfy the acceptance criterion that all p4 commands show a modal.

Migration: the reducer's `Reload` case sets `Runtime.ReloadRequested = $true` and returns. The main loop detects this flag, clears it, and performs the reload I/O via `Invoke-BrowserSideEffect` — identical to the existing pattern for `Describe` and `DeleteChange`.

### 5.4 Manual reopen

When `ShowCommandModal` is triggered by `F6`, the next `Render-BrowserState` call will draw the modal showing the latest history. No extra orchestration needed.

---

## 6) Rendering (modal overlay)

In `tui/Render.psm1`:

### 6.1 Overlay trigger

- If `State.Runtime.CommandModal.IsOpen` is true, draw modal over current frame.

### 6.2 Modal content

- Title: `p4 Commands`
- Busy row (if busy): `Running: <CurrentCommand>`
- History rows: `<HH:mm:ss> [OK|ERR] <DurationMs>ms  <CommandLine>`
- Footer hint:
  - while busy: `Please wait...`
  - idle: `[F6] Reopen  [Esc] Dismiss  [Q] Quit`

**Known limitation:** history is not scrollable in this iteration. If more than `MaxRows - 2` items exist, only the most recent ones are shown.

### 6.3 Geometry

- Bottom-sheet style:
  - width = full frame width − 4 (2-char margin each side)
  - height = `[Math]::Min([Math]::Floor($terminalHeight / 3), 12)` rows, minimum 4
  - anchored to bottom

### 6.4 Rendering rule

- Overlay is purely visual; no separate input focus model needed.
- Modal blocking is **implicit**: `Invoke-P4` is synchronous, so `[Console]::ReadKey` is never reached while a command is running. There is no explicit focus-trapping mechanism.

---

## 7) Step-by-step implementation order

1. Extract `Format-P4CommandLine` helper in `P4Cli.psm1`; update `Invoke-P4` to call it.
2. Add `$script:CommandHistoryMaxSize` constant and `CommandModal` runtime state + copy logic in reducer.
3. Add reducer handlers for `CommandStart`, `CommandFinish`, `ShowCommandModal`, `HideCommandModal`.
4. Move `Reload` I/O out of the reducer; add `ReloadRequested` flag pattern.
5. Add `F6` / `Esc` action mappings in input.
6. Extract `Invoke-BrowserSideEffect` helper and wire all p4 I/O blocks in the main loop.
7. Add modal drawing in render (plus status hint and duration display).
8. Add/adjust tests (P4Cli, Reducer, Render).
9. Run full test suite + analyzer.
10. Manual smoke test in terminal.

---

## 8) Test plan

### 8.1 `tests/P4Cli.Tests.ps1`

Add tests:

- `Format-P4CommandLine` correctly quotes arguments containing spaces
- `Format-P4CommandLine` leaves plain arguments unquoted
- `Invoke-P4` uses `Format-P4CommandLine` internally (argument string is consistent)

### 8.2 `tests/Reducer.Tests.ps1`

Add tests:

- `CommandStart` opens modal and sets busy/current command
- `CommandFinish` (success) appends history with `DurationMs`, closes modal
- `CommandFinish` (failure) appends history, keeps modal open
- `CommandFinish` trims history to `$script:CommandHistoryMaxSize`
- `ShowCommandModal` opens modal
- `HideCommandModal` is ignored while busy
- `Reload` action sets `ReloadRequested = $true` without performing I/O

### 8.3 `tests/Render.Tests.ps1`

Add tests:

- modal not rendered when closed
- modal rendered when open and includes current command text
- history rows rendered in expected order (newest first), include duration
- footer shows `Please wait...` while busy; shows dismiss hint when idle

---

## 9) Acceptance criteria

- Any p4 command triggered by browser flow causes modal to auto-open.
- Modal blocks interaction while command is active (implicit via synchronous I/O).
- Modal auto-closes on success.
- Modal stays open on failure; `Esc` dismisses it.
- History rows display command line and duration.
- `F6` reopens command history.
- History is bounded by `$script:CommandHistoryMaxSize`.
- `Reload` is handled outside the reducer; reducer remains pure.
- Existing interactions (filtering, describe, delete, reload) keep working.
- Full tests pass.

---

## 10) Optional follow-up (not in first iteration)

- Add scrolling within the history list for entries beyond the visible rows.
- Add copy-to-clipboard for selected history line.
- Add a toggle to always keep modal open after command completion (not just on failure).
