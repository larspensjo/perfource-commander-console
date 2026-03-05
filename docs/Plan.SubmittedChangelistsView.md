# Plan: Submitted Changelists View + Help Overlay (Source-Validated)

## Purpose

Add a second view mode for **submitted changelists** and a dedicated **help overlay** that keeps keybindings discoverable as the UI grows.

This revision is based on the current implementation in `tui/`, `p4/`, and `PerfourceCommanderConsole.psm1`, and updates the original plan where assumptions did not match source.

---

## What was validated in source

1. Current app state is single-view (`Data.AllChanges`) with no view mode or per-view cursor snapshots.
2. Reducer is pure and side effects are correctly handled in `Start-P4Browser` through `Invoke-BrowserSideEffect` and runtime flags (`ReloadRequested`, etc.).
3. Existing modal is command-log specific (`Runtime.CommandModal` + `Apply-ModalOverlay`), not a generic overlay system.
4. `Escape` is currently mapped to `HideCommandModal`; `F1` is currently unmapped and tested as unmapped.
5. Filtering is global/pending-oriented only (`No shelved files`, `No opened files`) and not view-aware.
6. No submitted changelist data/API/model functions exist in `p4/` yet.

---

## Corrections and recommendations

### C1) Keep reducer purity and reuse existing side-effect pattern

- Keep all P4 calls in `Start-P4Browser` (outside reducer).
- Add runtime flags for submitted loading instead of direct I/O in reducer actions.
- Continue using `Invoke-BrowserSideEffect` for command history and error handling.

### C2) Use `F1` for help; do not use `?` initially

- `F1` is reliable and layout-agnostic.
- `?` (`Oem2` + Shift concerns) is brittle and conflicts with future search input.

### C3) Preserve command modal semantics and add a separate help overlay

- Keep command modal behavior unchanged (especially busy-state semantics).
- Add independent help state (`Runtime.HelpOverlayOpen`) and rendering function.
- Overlay precedence: if command modal is open, render command modal; otherwise render help overlay.

### C4) Make filtering APIs view-aware (minimal extension)

- Extend filter APIs with `-ViewMode` while keeping default behavior compatible:
  - `Get-AllFilterNames -ViewMode 'Pending'|'Submitted'` (default `Pending`)
  - `Test-EntryMatchesFilter -ViewMode ...`
  - `Get-VisibleChangeIds -ViewMode ...`
- This avoids a second filtering engine and keeps tests straightforward.

### C5) Keep pagination explicit first (`L` key)

- Add `LoadMore` action and explicit `L` key.
- Avoid auto-load-on-scroll in MVP to reduce reducer/render complexity.

### C6) Add a small Phase 0 baseline fix for robustness

Two source-level issues should be corrected before adding complexity:

1. **Describe selection lifetime**: current detail rendering uses `Runtime.LastSelectedId`, but `Start-P4Browser` clears it immediately when consuming describe side effects. Persist detail target independently (for example `Runtime.DetailChangeId`) and render from that.
2. **Reload max consistency**: reload currently hardcodes `200` instead of honoring `Start-P4Browser -MaxChanges`. Store and reuse configured max.

These are small, isolated changes that reduce surprise while implementing submitted view.

---

## Revised implementation plan

## Phase 0: Baseline correctness (recommended first)

### 0.1 Describe target persistence

- Introduce `Runtime.DetailChangeId`.
- `Describe` action sets `DetailChangeId` (and request marker if needed).
- Render detail pane by looking up selected/focused id and `DescribeCache`, not transient one-shot flags.

### 0.2 Reload max consistency

- Persist configured max changes in state/runtime.
- Use it for initial and reload commands in pending view.

### 0.3 Tests

- Extend reducer/render tests to lock in persistent describe behavior.
- Add/adjust test for reload honoring configured max.

---

## Phase 1: Help overlay

### 1.1 Input

- Map `F1` to `ToggleHelpOverlay`.
- Keep `Escape -> HideCommandModal` mapping for compatibility.
- Reducer handles `HideCommandModal` as: close help first (if open), else close command modal when allowed.

### 1.2 State

- Add `Runtime.HelpOverlayOpen = $false` to `New-BrowserState` and `Copy-BrowserState`.

### 1.3 Reducer

- Add actions:
  - `ToggleHelpOverlay`
  - `HideHelpOverlay` (optional internal action; can also reuse existing hide action path)
- While help overlay is open:
  - `Escape` closes help.
  - Any non-overlay key closes help and is discarded (MVP behavior).

### 1.4 Render

- Add `Build-HelpOverlayRows` in `tui/Render.psm1`.
- Reuse existing box helpers and overlay composition approach.
- Keep command modal rendering precedence over help overlay.

### 1.5 Status bar simplification

- Replace long key legend with compact status text.
- Recommended base:
  - `[Pending] Filtered: X/Y | [F1] Help [Q] Quit`

### 1.6 Tests

- `tests/Input.Tests.ps1`: `F1 -> ToggleHelpOverlay` (replace current “F1 unmapped” assertion).
- `tests/Reducer.Tests.ps1`: overlay open/close and escape behavior.
- `tests/Render.Tests.ps1`: help overlay row presence and precedence with command modal.

---

## Phase 2: View-mode state plumbing

### 2.1 State shape

In `New-BrowserState`:

```powershell
Ui.ViewMode = 'Pending'   # Pending | Submitted

Cursor.ViewSnapshots = @{
    Pending   = @{ ChangeIndex = 0; ChangeScrollTop = 0 }
    Submitted = @{ ChangeIndex = 0; ChangeScrollTop = 0 }
}

Data.SubmittedChanges   = @()
Data.SubmittedHasMore   = $true
Data.SubmittedOldestId  = $null
```

### 2.2 Copy semantics

- Deep copy `Cursor.ViewSnapshots`.
- Copy submitted data arrays/flags.
- Preserve existing shared-reference behavior for `DescribeCache` unless intentionally changed.

### 2.3 Reducer actions

- Add `SwitchView` action with `View = 'Pending'|'Submitted'`.
- On switch:
  1. Save current view cursor snapshot.
  2. Set `Ui.ViewMode`.
  3. Restore target view cursor snapshot.
  4. Reset filter cursor.
  5. Update derived state.
  6. If switching to `Submitted` first time and list empty, set runtime load-more request flag.

### 2.4 Input bindings

- `D1` -> `SwitchView Pending`
- `D2` -> `SwitchView Submitted`
- `L`  -> `LoadMore`

### 2.5 Derived-state branch

- In `Update-BrowserDerivedState`, select source list by `Ui.ViewMode`:
  - Pending -> `Data.AllChanges`
  - Submitted -> `Data.SubmittedChanges`
- Use view-specific filters via `Get-AllFilterNames -ViewMode`.

### 2.6 Tests

- `tests/Reducer.Tests.ps1`: cursor snapshot save/restore and invalid-view handling.
- `tests/Input.Tests.ps1`: `1`, `2`, and `L` mappings.
- `tests/Filtering.Tests.ps1`: view-mode-specific names and predicates.

---

## Phase 3: Submitted data layer

### 3.1 Models

In `p4/Models.psm1`, add:

```powershell
function ConvertTo-SubmittedChangelistEntry {
    param([Parameter(Mandatory)][object]$Changelist)

    $title = [string]$Changelist.Description
    if ([string]::IsNullOrWhiteSpace($title)) { $title = '(no description)' }

    [pscustomobject]@{
        Id         = "$($Changelist.Change)"
        Title      = $title
        User       = [string]$Changelist.User
        Client     = [string]$Changelist.Client
        SubmitTime = $Changelist.Time
        Captured   = $Changelist.Time
        Kind       = 'Submitted'
    }
}
```

### 3.2 P4 CLI

In `p4/P4Cli.psm1`, add:

- `Get-P4SubmittedChangelists -Max -BeforeChange`
- `Get-P4SubmittedChangelistEntries -Max -BeforeChange`

Recommended args:

```powershell
@('-ztag', 'changes', '-l', '-s', 'submitted', '-m', "$Max")
```

When `BeforeChange > 0`, append revision range to fetch older CLs only.

### 3.3 Load-more side effect in main loop

- Add runtime flag `Runtime.LoadMoreRequested`.
- On `LoadMore` in reducer:
  - Set flag only when `ViewMode = 'Submitted'` and `SubmittedHasMore` is true.
- In `Start-P4Browser`, consume flag:
  1. Compute `BeforeChange` from `Data.SubmittedOldestId`.
  2. Fetch next page (e.g., 50).
  3. Append to `Data.SubmittedChanges`.
  4. Update `SubmittedOldestId`.
  5. Set `SubmittedHasMore = $false` when page is short.
  6. Recompute derived state.

### 3.4 Tests

- `tests/P4Cli.Tests.ps1` for submitted parser and args.
- Mock `Invoke-P4`/`Get-P4Info` as done in existing tests.

---

## Phase 4: Submitted rendering and filters

### 4.1 List pane

- Pane title becomes view-aware:
  - `[Pending Changelists]`
  - `[Submitted Changelists]`
- Extend `Build-ChangeSegments` to support submitted entries by `Kind`.
- Submitted compact row format:
  - `> 123456 jsmith Fix widget crash`

### 4.2 Expanded details row

- Add `Build-SubmittedChangeDetailSegments`:
  - user + submit timestamp
  - keep color palette consistent with existing style

### 4.3 Detail pane

- Keep describe behavior shared across views.
- Cache key remains numeric changelist id.

### 4.4 Load-more hint row

- In submitted view, when `SubmittedHasMore` and near list bottom, render:
  - `── [L] Load more ──`

### 4.5 Filters

Submitted filter set:

- `My changes`: entry user equals current `p4 info` user
- `Today`: entry submit date equals today
- `This week`: entry submit time within last 7 days

Pending filters remain unchanged.

### 4.6 Tests

- `tests/Render.Tests.ps1`: submitted row rendering, view titles, load-more hint.
- `tests/Filtering.Tests.ps1`: submitted predicates and view-mode filter lists.

---

## Phase 5: Integration polish

1. `DeleteChange` becomes no-op in submitted view.
2. `F5` reloads active view:
   - Pending: existing pending reload path.
   - Submitted: reset submitted pagination + first page fetch.
3. Status bar always includes active view badge and concise controls.
4. Empty submitted list shows explicit placeholder text.
5. On submitted fetch failure, keep already-loaded rows and surface `LastError`.

---

## Verification checklist

1. Lint: `pwsh -NoProfile -File .vscode/Invoke-Linter.ps1`
2. Tests: `Invoke-Pester tests/`
3. Manual validation:
   - Start in pending view unchanged.
   - `F1` opens/closes help overlay.
   - `1`/`2` switches views with per-view cursor restore.
   - First switch to submitted triggers initial load.
   - `L` appends more submitted CLs.
   - `Enter` describe works in both views.
   - `F5` reloads active view.
   - Delete ignored in submitted view.

---

## Files expected to change

- `p4/Models.psm1`
- `p4/P4Cli.psm1`
- `tui/Input.psm1`
- `tui/Reducer.psm1`
- `tui/Render.psm1`
- `tui/Filtering.psm1`
- `PerfourceCommanderConsole.psm1`
- `tests/Input.Tests.ps1`
- `tests/Reducer.Tests.ps1`
- `tests/Render.Tests.ps1`
- `tests/Filtering.Tests.ps1`
- `tests/P4Cli.Tests.ps1`
