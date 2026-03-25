# PerFourceCommanderConsole — Resolve Conflicts Plan

> Status: design phase — not yet implemented.

## Purpose

Enable interactive conflict resolution from the Files screen by launching a
configured external merge tool via `p4 resolve`. The user navigates to an
unresolved file and invokes **Resolve…** from either a keyboard shortcut or the
File menu. The application delegates to Perforce's resolve mechanism, which in
turn can launch a user-configured external merge tool (e.g. Beyond Compare,
KDiff3, P4Merge).

This plan is written against the current architecture (2026-03-25): reducer-driven
UDF, `Ui.ScreenStack` for screen hierarchy, async `ThreadJob` execution, and the
responsive-command patterns described in
[Plan.ResponsiveCommandExecution.md](Plan.ResponsiveCommandExecution.md).

Resolve execution is modelled as a normal `PendingRequest` flowing through the
existing async worker lane — not as a one-off blocking path — so that command
logging, cancellation semantics, and the modal/status-bar surfaces all work
consistently.

---

## Goals

1. Allow the user to resolve a single unresolved file from the Files screen via
   a **Resolve…** command.
2. Support configuring an external merge tool (application path + arguments) that
   Perforce will launch during `p4 resolve`.
3. Persist the merge tool configuration so it survives across sessions.
4. After resolve completes, refresh the file list so `IsUnresolved` reflects the
   new state.
5. Keep the workflow simple and correct — one file at a time for the initial
   implementation.

## Non-Goals (for initial implementation)

- Batch-resolving all unresolved files in a changelist at once.
- Built-in three-way merge viewer inside the TUI.
- Graphical file picker for the merge tool path (the user provides the path
  directly).
- Supporting `p4 resolve` accept flags (`-am`, `-at`, `-ay`) without a merge
  tool — the initial workflow always launches the configured tool.
- Auto-detecting installed merge tools.

---

## UX Overview

### Entry point

From the **Files screen**, the user focuses on a file that has `IsUnresolved =
$true`. The command is available via:

| Trigger           | Action                                       |
|-------------------|----------------------------------------------|
| `R`               | Keyboard shortcut on the Files screen        |
| File menu → **Resolve…** | Menu item (accelerator `E`)           |

If no merge tool is configured yet, or the user presses `Shift+R`, the
**Resolve Settings** overlay opens first (see below).

### Resolve flow

```
┌─ Files screen ─────────────────────────────────────────────────────────────┐
│  User focuses on an unresolved file and presses R                          │
├────────────────────────────────────────────────────────────────────────────┤
│  1. Validate: file is unresolved → else show LastError warning             │
│  2. Check merge tool configuration → if missing, open settings overlay     │
│  3. Set PendingRequest.Kind = 'ResolveFile'                                │
│  4. Async worker runs `p4 resolve <depot-file>` (external tool opens)      │
│  5. Command modal shows "Resolving …" with Esc available                   │
│  6. External tool exits → worker returns typed completion                   │
│  7. Reducer receives ResolveCompleted → triggers dual refresh              │
│     a. File-list refresh (LoadFiles) → updates IsUnresolved per file       │
│     b. Changelist-summary refresh (ReloadPending) → updates unresolved     │
│        badge counts on the parent changelist                               │
│  8. Outcome appears in command log and status bar via existing surfaces     │
└────────────────────────────────────────────────────────────────────────────┘
```

### Resolve Settings overlay

The settings overlay reuses the existing `Menu` overlay mode. When no merge tool
is configured or when explicitly requested (`Shift+R`), a menu opens listing
predefined merge tool presets plus a "Current: …" header showing the active
`P4MERGE` value:

```
┌──────────────────────────────────────────┐
│  Select merge tool                       │
│                                          │
│  Current: (not set)                      │
│  ─────────────────                       │
│  1. P4Merge                              │
│  2. Beyond Compare                       │
│  3. KDiff3                               │
│  ─────────────────                       │
│  Enter path manually…                    │
│                                          │
│  [Enter] Select   [Esc] Cancel           │
└──────────────────────────────────────────┘
```

Selecting a preset saves via `p4 set P4MERGE=<path>`. "Enter path manually…"
opens a `Confirm` overlay with a text prompt (reusing `Runtime.ModalPrompt`)
where the user types the full path. This avoids introducing a new text-entry
overlay primitive — the confirm/prompt mechanism already exists.

---

## Merge Tool Configuration

### Configuration mechanism

Perforce supports configuring merge tools via **P4 environment variables** and
**`p4 set`**. This is the preferred mechanism because:

- It integrates naturally with Perforce's own resolve infrastructure.
- The settings persist across sessions (stored by `p4 set`).
- No separate configuration file is needed.
- The external tool is launched by `p4 resolve` itself, not by our application.

### Relevant Perforce settings

| Variable       | Purpose                              | Example                                    |
|----------------|--------------------------------------|---------------------------------------------|
| `P4MERGE`      | External merge tool executable       | `C:\Program Files\Beyond Compare 5\BCompare.exe` |
| `P4MERGEARGS`  | Arguments (optional, Perforce ≥2023) | `%1 %2 %b %r`                              |

> **Note:** `P4MERGE` is the standard Perforce variable. When set, `p4 resolve`
> will invoke the specified tool for content merges. The argument placeholders
> (`%1`, `%2`, `%b`, `%r`) are Perforce conventions for theirs/yours/base/result.

### Reading and writing configuration

`p4 set` is a local-only metadata command. It does **not** produce `-ztag -Mj`
JSON output, so the wrappers call `p4 set` directly (via `Start-Process` or
`& p4`) rather than through `Invoke-P4`, which always prepends global flags.

```powershell
# Read current merge tool
function Get-P4MergeTool {
    # Runs: p4 set P4MERGE
    # Parses: "P4MERGE=<path> (set)" or empty
    # Returns: [pscustomobject]@{ Path = '...'; IsSet = $true/$false }
}

# Set merge tool
function Set-P4MergeTool {
    param([string]$ToolPath)
    # Runs: p4 set P4MERGE=<ToolPath>
}
```

### Predefined presets

```powershell
$script:MergeToolPresets = @(
    [pscustomobject]@{
        Name = 'P4Merge'
        Path = 'C:\Program Files\Perforce\p4merge.exe'
        Args = ''   # p4merge uses default Perforce conventions
    },
    [pscustomobject]@{
        Name = 'Beyond Compare'
        Path = 'C:\Program Files\Beyond Compare 5\BCompare.exe'
        Args = '%1 %2 %b %r'
    },
    [pscustomobject]@{
        Name = 'KDiff3'
        Path = 'C:\Program Files\KDiff3\kdiff3.exe'
        Args = '%b %1 %2 -o %r'
    }
)
```

Presets are convenience defaults — the actual stored value is always the
`P4MERGE` Perforce variable applied via `p4 set`.

---

## Data Model Additions

### State additions

No new top-level state fields. The resolve workflow uses existing surfaces:

| Surface                    | Used for                                                    |
|----------------------------|-------------------------------------------------------------|
| `Runtime.PendingRequest`   | `{ Kind = 'ResolveFile'; … }` to initiate the async worker  |
| `Runtime.ActiveCommand`    | Tracks the in-flight `p4 resolve` process                   |
| `Runtime.ModalPrompt`      | Shows "Resolving …" busy modal while the merge tool is open  |
| `Runtime.LastError`        | Displays resolve failures                                   |
| Command log                | Records the resolve command outcome                         |
| `Ui.OverlayMode = 'Menu'` | Merge tool selection overlay                                |

### No new model types

The resolve workflow operates on existing `P4FileEntry` objects (specifically
`DepotPath` and `IsUnresolved`). No new model type is required.

---

## Reducer Actions

| Action                   | Payload                          | Effect                                                  |
|--------------------------|----------------------------------|---------------------------------------------------------|
| `ResolveFile`            | —                                | Validate focused file is unresolved; set `PendingRequest = { Kind = 'ResolveFile'; DepotPath; Change }` |
| `OpenResolveSettings`    | —                                | Open merge-tool selection overlay (`OverlayMode = 'Menu'`) |
| `SelectMergeTool`        | `{ PresetIndex }`                | Persist selected preset via `p4 set P4MERGE=…`; close overlay |
| `ResolveCompleted`       | `{ Success, Message, ObservedCommands }` | Log to command history; on success set `PendingRequest = 'LoadFiles'` then chain `ReloadPending` to refresh both file-level and changelist-level unresolved state |

The settings overlay reuses the existing `MenuSelect` / `MenuAccelerator` /
`HideCommandModal` action types since it is rendered as a `Menu` overlay. No
new overlay-specific actions are needed.

For the "Enter path manually…" option, the reducer transitions to a `Confirm`
overlay with a text prompt. `AcceptDialog` saves the entered path via `p4 set`.

---

## P4 CLI Integration

### New functions in `p4/P4Cli.psm1`

```powershell
function Invoke-P4Resolve {
    param(
        [string]$DepotPath,
        [scriptblock]$Observer = $null,
        [scriptblock]$ProcessObserver = $null
    )
    # Runs: p4 resolve <depot-path>
    #
    # IMPORTANT: this command launches an external merge tool and blocks until
    # the user finishes.  It requires a dedicated execution path because:
    #   1. `-ztag -Mj` flags must NOT be prepended (resolve is interactive).
    #   2. The timeout must be genuinely unlimited.
    #
    # Implementation: call `p4` directly via Start-Process / System.Diagnostics.Process
    # rather than through `Invoke-P4`, which always prepends global flags.
    # Use WaitForExit() with no timeout argument (or Int32.MaxValue) — the
    # current Invoke-P4 treats TimeoutMs = 0 as an immediate timeout, not
    # infinite, and TimeoutMs = -1 resolves to a finite category default.
    #
    # The observer and process-observer callbacks are invoked manually so
    # that the async worker contract (command logging, process tracking)
    # stays intact.
}

function Get-P4MergeTool {
    # Runs: p4 set P4MERGE  (directly, not through Invoke-P4)
    # Returns: [pscustomobject]@{ Path = '...'; IsSet = $true/$false }
}

function Set-P4MergeTool {
    param([string]$ToolPath)
    # Runs: p4 set P4MERGE=<ToolPath>  (directly, not through Invoke-P4)
}
```

### Command category

`p4 resolve` is already classified as `Mutating` by `Get-P4CommandCategory`.
However, `Invoke-P4Resolve` does **not** flow through `Invoke-P4` (see above),
so the category is only relevant for display purposes in the command log.

No new command category is introduced. The timeout is handled explicitly inside
`Invoke-P4Resolve` (unlimited wait via `Process.WaitForExit()` with no timeout
argument).

`p4 set` is a local-only metadata command called directly — it does not use
`Invoke-P4` either, since `p4 set` does not produce `-ztag -Mj` output.

---

## Async Execution Strategy

### Resolve runs through the existing async request lane

Resolve is modelled as a standard `PendingRequest` (`Kind = 'ResolveFile'`) that
flows through `Invoke-BrowserStartAsyncRequest`, the `ThreadJob` executor, and
the typed-completion reducer — exactly like `DeleteChange`, `ShelveFiles`, or
`SubmitChange`.

This gives us command logging, `ModalPrompt` busy state, `Esc` cancellation
semantics, and process tracking (via `ProcessObserver`) for free.

The key difference from other workers is that `Invoke-P4Resolve` calls `p4`
directly (no `-ztag -Mj`, unlimited wait) instead of delegating to `Invoke-P4`.
The observer and process-observer callbacks are invoked manually to preserve the
contract.

### AsyncWorkers entry

```powershell
$script:AsyncWorkers['ResolveFile'] = {
    param([pscustomobject]$Envelope, [string]$ModuleRoot)
    if (![string]::IsNullOrEmpty($ModuleRoot)) {
        Import-Module (Join-Path $ModuleRoot 'p4\Models.psm1') -Force
        Import-Module (Join-Path $ModuleRoot 'p4\P4Cli.psm1')  -Force
    }
    $observed = [System.Collections.Generic.List[pscustomobject]]::new()
    $processObserver = {
        param($EventType,$ProcessId,$ExitCode)
        if (-not [string]::IsNullOrWhiteSpace([string]$Envelope.ProcessEventFile)) {
            $payload = [pscustomobject]@{ EventType=$EventType; RequestId=[string]$Envelope.RequestId; ProcessId=$ProcessId; ExitCode=$ExitCode }
            Add-Content -LiteralPath ([string]$Envelope.ProcessEventFile) -Value ($payload | ConvertTo-Json -Compress)
        }
    }
    Register-P4Observer {
        param($CommandLine,$RawLines,$ExitCode,$ErrorOutput,$StartedAt,$EndedAt,$DurationMs)
        $null = $RawLines
        $observed.Add([pscustomobject]@{ CommandLine=$CommandLine;ExitCode=$ExitCode;Succeeded=($ExitCode -eq 0)
            ErrorText=$ErrorOutput;StartedAt=$StartedAt;EndedAt=$EndedAt;DurationMs=$DurationMs;FormattedLines=@();OutputCount=0;SummaryLine='' })
    }
    try {
        Invoke-P4Resolve -DepotPath ([string]$Envelope.DepotPath) -Observer $null -ProcessObserver $processObserver
        return [pscustomobject]@{ Type='MutationCompleted'; RequestId=$Envelope.RequestId; Generation=$Envelope.Generation
            MutationKind='ResolveFile'; DepotPath=[string]$Envelope.DepotPath; ObservedCommands=@($observed); Success=$true; Outcome='Completed' }
    } catch {
        $outcome = if (Test-IsP4TimeoutError -Message $_.Exception.Message) { 'TimedOut' } else { 'Failed' }
        return [pscustomobject]@{ Type='AsyncCommandFailed'; RequestId=$Envelope.RequestId; Generation=$Envelope.Generation
            MutationKind='ResolveFile'; DepotPath=[string]$Envelope.DepotPath; ErrorText=$_.Exception.Message; ObservedCommands=@($observed); Success=$false; Outcome=$outcome }
    } finally { Unregister-P4Observer }
}
```

### Completion flow — dual refresh

After resolve completes, **two** refresh paths are needed:

1. **File-list refresh** — reload files for the active changelist so that
   per-file `IsUnresolved` states update on the Files screen.
2. **Changelist-summary refresh** — reload pending changelists so that the
   unresolved badge/count on the parent changelist row updates.

Without both refreshes, the file list can show the file as resolved while the
changelist summary still displays a stale unresolved count.

```
ResolveFile worker completes
  → Reducer receives MutationCompleted { MutationKind = 'ResolveFile' }
  → Reducer logs to command history (existing mechanism)
  → Reducer chains PendingRequest = { Kind = 'LoadFiles' } to refresh file list
  → On LoadFiles completion, reducer chains PendingRequest = { Kind = 'ReloadPending' }
    to refresh changelist unresolved counts
```

This chained-refresh pattern is consistent with how other mutations (e.g.
DeleteChange, MoveFiles) already trigger follow-up reloads.

---

## Menu and Input Integration

### File menu addition

Add **Resolve…** to the File menu in `$script:MenuDefinitions['File']`, placed
after SubmitChange and before the separator:

```powershell
[pscustomobject]@{
    Id          = 'ResolveFile'
    Label       = 'Resolve…'
    Accelerator = 'E'
    IsSeparator = $false
    IsEnabled   = { param($s)
        # Enabled only on Files screen with an unresolved file focused
        $screenProp = $s.Ui.PSObject.Properties['ScreenStack']
        if ($null -eq $screenProp -or $screenProp.Value.Count -eq 0) { return $false }
        $screen = $screenProp.Value[-1]
        if ($screen -ne 'Files') { return $false }
        $entry = Get-FocusedFileEntry -State $s
        $null -ne $entry -and $entry.IsUnresolved
    }
}
```

### Keyboard shortcut

In `ConvertFrom-KeyInfoToAction`, when on the Files screen:

| Key       | Action                                                    |
|-----------|-----------------------------------------------------------|
| `R`       | `ResolveFile` (if focused file is unresolved)             |
| `Shift+R` | `OpenResolveSettings` (configure merge tool)              |

---

## Implementation Phases

### Phase 1 — Configuration (MVP foundation)

**Objective:** Read and write the `P4MERGE` Perforce variable; display merge
tool presets in a menu overlay.

Work items:
- [ ] Add `Get-P4MergeTool` and `Set-P4MergeTool` to `p4/P4Cli.psm1`
      (call `p4 set` directly — not through `Invoke-P4`)
- [ ] Define `$script:MergeToolPresets` (P4Merge, Beyond Compare, KDiff3)
- [ ] Add `OpenResolveSettings` reducer action → opens `Menu` overlay with
      presets; `SelectMergeTool` saves via `p4 set`; "Enter path manually…"
      transitions to `Confirm` overlay with text prompt
- [ ] Render merge-tool menu in `tui/Render.psm1` (reuse existing menu overlay)
- [ ] Handle `Shift+R` in `tui/Input.psm1` to dispatch `OpenResolveSettings`
- [ ] Unit tests for `Get-P4MergeTool` / `Set-P4MergeTool`
- [ ] Unit tests for reducer action and overlay state transitions

Acceptance criteria:
- User can open settings overlay with `Shift+R`.
- Selecting a preset persists via `p4 set P4MERGE=...`.
- "Enter path manually…" opens a confirm-style prompt for the full path.
- Cancelling (Esc) discards changes.

### Phase 2 — Resolve execution

**Objective:** Launch `p4 resolve` for the focused unresolved file using the
configured merge tool, flowing through the existing async request lane.

Work items:
- [ ] Add `Invoke-P4Resolve` to `p4/P4Cli.psm1` (direct process execution,
      no `-ztag -Mj`, unlimited wait)
- [ ] Add `ResolveFile` reducer action with validation
      (check IsUnresolved; check P4MERGE is set; set PendingRequest)
- [ ] Register `ResolveFile` async worker in `$script:AsyncWorkers`
      (follows existing Envelope + observer contract)
- [ ] Add `ResolveFile` entry in `Get-AsyncDisplayCommandLine`
- [ ] Add `ResolveFile` envelope extras in `Invoke-BrowserStartAsyncRequest`
- [ ] Handle `MutationCompleted { MutationKind = 'ResolveFile' }` in reducer:
      chain `LoadFiles` then `ReloadPending` to refresh both files and
      changelist unresolved counts
- [ ] Add `ResolveFile` menu item to File menu
- [ ] Add `R` keyboard shortcut on Files screen in `tui/Input.psm1`
- [ ] Show `LastError` when `R` is pressed on a non-unresolved file
- [ ] Integration tests (with mocked `p4 resolve`)

Acceptance criteria:
- `R` on an unresolved file launches the configured merge tool.
- Command modal shows "Resolving …" while the external tool is open.
- If no merge tool is configured, the settings overlay opens first.
- After the merge tool closes, both the file list and changelist
  unresolved counts refresh.
- Command log records the resolve outcome.
- `R` on a non-unresolved file shows LastError warning.

### Phase 3 — Polish and edge cases

**Objective:** Handle errors, edge cases, and improve discoverability.

Work items:
- [ ] Validate merge tool path exists before launching resolve
- [ ] Handle `p4 resolve` errors (exit code, stderr)
- [ ] When a file has multiple resolve records (e.g. branched from two sources),
      handle iteratively or warn
- [ ] Add resolve hint to the file inspector when `IsUnresolved = $true`
- [ ] Add resolve status to the Files screen status bar (e.g. "3 unresolved")
- [ ] Consider: `p4 resolve -n` dry-run to preview resolve actions

---

## Rendering Details

### Settings overlay

The settings overlay is a standard `Menu` overlay. The menu items are built
dynamically from `$script:MergeToolPresets` plus a "Enter path manually…" item.
The existing menu rendering in `Build-MenuOverlayRows` handles layout, highlight,
and keyboard navigation.

### Resolve busy state

While the resolve worker is active, `Runtime.ModalPrompt.IsBusy = $true` and
`Runtime.ModalPrompt.CurrentCommand` shows `p4 resolve <depot-path>`. The
existing `Build-CommandModalRows` renderer displays this with elapsed time and
Esc-to-cancel hint.

### Status messages

Resolve outcomes flow through existing surfaces:

| Scenario                          | Surface                                        |
|-----------------------------------|------------------------------------------------|
| Resolve launched                  | Command modal: `p4 resolve {depot-path}`       |
| Resolve succeeded                 | Command log entry (Succeeded = $true)           |
| Resolve failed                    | `Runtime.LastError` + command log entry         |
| No merge tool configured          | `Runtime.LastError`: "No merge tool — Shift+R"  |
| Focused file is not unresolved    | `Runtime.LastError`: "File is not unresolved"   |

---

## File Organization

| File                | Changes                                                |
|---------------------|--------------------------------------------------------|
| `p4/P4Cli.psm1`    | `Get-P4MergeTool`, `Set-P4MergeTool`, `Invoke-P4Resolve`, `Interactive` category |
| `tui/Reducer.psm1`  | Resolve actions, settings modal state, menu item       |
| `tui/Input.psm1`    | `R` / `Shift+R` shortcuts, settings modal key handling |
| `tui/Render.psm1`   | Settings modal rendering, resolve status rendering     |
| `PerfourceCommanderConsole.psm1` | `ResolveFile` async worker            |
| `tests/Reducer.Tests.ps1` | Reducer action tests                            |
| `tests/P4Cli.Tests.ps1`   | P4 CLI wrapper tests                            |

---

## Risks and Mitigations

| Risk                                              | Mitigation                                           |
|---------------------------------------------------|------------------------------------------------------|
| `p4 resolve` blocks the TUI until merge tool exits | Runs in async worker; command modal shows busy state. Console may not repaint until the external tool closes, but the worker contract stays intact. Re-render full frame after resolve returns. |
| `P4MERGE` not set and user skips settings          | Guard: open settings overlay automatically before first resolve. |
| Merge tool path doesn't exist on disk              | Validate with `Test-Path` before launching; show `LastError`. |
| `p4 set` unavailable (permissions, non-standard setup) | Fall back to `$env:P4MERGE` environment variable. |
| `p4 resolve` returns non-zero exit code            | Parse exit code and stderr; set `LastError` + log in command history. |
| File has multiple resolve records                  | Phase 3 concern; initial MVP resolves all pending records for the file. |
| Console state corrupted after external tool        | Re-render full frame after resolve returns (invalidate `$script:PreviousFrame`). |
| Changelist unresolved count stale after resolve    | Dual refresh: `LoadFiles` for file list, then `ReloadPending` for changelist summary. |

---

## Future Ideas (post-MVP)

- **Batch resolve:** Resolve all unresolved files in a changelist sequentially.
- **Accept modes:** Support `p4 resolve -am` (accept merge), `-at` (accept
  theirs), `-ay` (accept yours) as quick-resolve options without a merge tool.
- **Resolve preview:** Run `p4 resolve -n` to show what would be resolved before
  actually resolving.
- **Auto-detect merge tools:** Scan common install paths to suggest presets.
- **Cross-platform paths:** Detect OS and adjust preset paths for Linux/macOS.
