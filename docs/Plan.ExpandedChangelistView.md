# Plan: Toggleable Expanded Changelists View (Revised)

## Summary

Add an `E` key toggle that switches the Changelists pane between:

- **Compressed mode**: current 1-row-per-CL layout.
- **Expanded mode**: 2 rows per CL (title row + detail row with opened count, shelved count, date).

This revision is aligned to the current codebase and emphasizes correctness-by-construction, reducer purity, and robust parsing/fallback behavior.

---

## Current Code Observations (important for implementation)

1. `p4/P4Cli.psm1` currently computes only boolean opened/shelved state via sets.
2. `tui/Reducer.psm1` and `tui/Render.psm1` use different changelist viewport math today (`ListPane.H - 1` vs `ListPane.H - 2`), which is a pre-existing drift risk.
3. `tui/Render.psm1` list rendering assumes one inner row maps to one CL index.
4. No input tests currently exist for key bindings.

The plan below resolves these while keeping existing behavior stable.

---

## Architecture + Robustness Decisions

| Decision | Why |
|---|---|
| Keep reducer pure; keep p4 I/O in side-effects only | Preserves unidirectional data flow and testability.
| Introduce small pure helpers for row geometry/parsing | Removes duplicated logic and prevents render/reducer drift.
| Keep `HasShelvedFiles` / `HasOpenedFiles` | Avoids breaking existing filters and tests.
| Add counts as additive fields (`OpenedFileCount`, `ShelvedFileCount`) | Enables richer UI without changing filtering semantics.
| Use batched shelved describe with chunking + graceful fallback | Avoids command-line length issues and startup brittleness.
| Keep backward-compatible wrapper for `Get-P4OpenedChangeNumbers` (optional but recommended) | Minimizes breakage for internal callers/tests during transition.

---

## Implementation Plan

### 1) Data parsing helpers (pure, testable)

- In `p4/P4Cli.psm1`, add pure helpers:
  - `ConvertFrom-P4OpenedLinesToFileCounts -Lines <string[]>` → `Dictionary[int,int]`.
  - `ConvertFrom-P4DescribeShelvedLinesToFileCounts -Lines <string[]>` → `Dictionary[int,int]`.
- Parsing rule for shelved counts: track current `change` record, increment on `depotFile\d+` keys.
- Keep these helpers free of p4 calls so they can be unit-tested directly.

### 2) Data layer functions

- Replace internal usage of `Get-P4OpenedChangeNumbers` with new `Get-P4OpenedFileCounts`.
- Keep `Get-P4OpenedChangeNumbers` as adapter (build set from dictionary keys) during migration.
- Add `Get-P4ShelvedFileCounts -ChangeNumbers <int[]>`:
  - Return empty dictionary when no input.
  - Execute `p4 -ztag describe -S -s` in **chunks** (e.g., 50–100 change numbers per call).
  - Merge chunk dictionaries into one result.
  - On describe failure, **degrade gracefully** to empty shelved counts (do not fail loading changelists).

### 3) Model wiring

- Extend `ConvertTo-ChangelistEntry` in `p4/Models.psm1`:
  - New optional params: `[int]$OpenedFileCount = 0`, `[int]$ShelvedFileCount = 0`.
  - Output new fields.
  - Derive booleans from counts when booleans are not explicitly passed (or pass booleans from caller, but keep invariant `Has*Files == (Count -gt 0)`).
- In `Get-P4ChangelistEntries`:
  - Fetch opened dictionary and shelved dictionary once.
  - For each CL, pull counts with default `0`.
  - Pass counts through to model conversion.

### 4) State + reducer geometry consistency

- Add `Ui.ExpandedChangelists = $false` in `New-BrowserState` and copy it in `Copy-BrowserState`.
- In reducer, add helpers and use them everywhere changelist paging/clamping is computed:
  - `Get-ChangeInnerViewRows($State)` (use `ListPane.H - 2`, matching render semantics).
  - `Get-ChangeRowsPerItem($State)` (1 or 2, with safe fallback to 1 if viewport too small).
  - `Get-ChangeViewCapacity($State)` (how many CLs can be fully displayed).
- Add action `'ToggleChangelistView'`:
  - Flip flag.
  - Re-clamp `ChangeIndex`/`ChangeScrollTop` via `Update-BrowserDerivedState`.
  - Preserve focused CL whenever possible.
- Update `PageUp/PageDown` step size in changelists pane to use view capacity helper.

### 5) Input binding

- In `tui/Input.psm1`, bind key `'E'` to `@{ Type = 'ToggleChangelistView' }`.

### 6) Rendering

- Add `Build-ChangeDetailSegments` in `tui/Render.psm1`.
  - Example: `📁 3  📦 2  2025-03-01`.
  - Suggested colors: icons `DarkCyan`, counts `Gray`, date `DarkGray`.
  - If a count field is missing/null, render `0`.
- In `Build-FrameFromState` changelist block:
  - Compute `$rowsPerCl` from state.
  - Map inner row → CL index with floor division.
  - Render title row via `Build-ChangeSegments`; detail row via `Build-ChangeDetailSegments`.
  - Apply selected-row background (`DarkCyan`) to both rows of selected CL.
- Scrollbar math in expanded mode:
  - Use row-based thumb totals (`TotalItems = VisibleCount * rowsPerCl`).
  - Convert CL scroll-top to row scroll-top (`ScrollTopRows = ChangeScrollTop * rowsPerCl`).
  - Ensure markers appear consistently across both rows for each CL slot.

### 7) Status bar discoverability

- Update `Build-StatusBarRow` hint text to include mode-aware prompt:
  - `... [E] Expand ...` when collapsed.
  - `... [E] Collapse ...` when expanded.

### 8) Tests

- `tests/P4Cli.Tests.ps1`
  - Add tests for `Get-P4OpenedFileCounts` (counts, empty output, no-open-files error, unexpected error).
  - Add tests for `Get-P4ShelvedFileCounts`:
    - batched describe parsing,
    - empty input,
    - chunk merge behavior,
    - graceful fallback behavior.
  - Update existing `Get-P4ChangelistEntries` expectations to include new count fields.
- `tests/Reducer.Tests.ps1`
  - Add `'ToggleChangelistView'` test:
    - toggles flag,
    - preserves/validates cursor bounds,
    - page navigation uses expanded capacity.
  - Add regression test for viewport calculation consistency.
- `tests/Render.Tests.ps1`
  - Add `Build-ChangeDetailSegments` tests (counts/date text and color segments).
  - Add expanded frame test verifying 2-row representation and selected background on both rows.
  - Add scrollbar-marker behavior test in expanded mode.
- **New file:** `tests/Input.Tests.ps1`
  - Verify `E` maps to `ToggleChangelistView`.
  - Keep quick coverage for existing key mappings to prevent regressions.

---

## Verification Checklist

1. Lint: `pwsh -NoProfile -File .vscode/Invoke-Linter.ps1` (zero warnings/errors).
2. Tests: `Invoke-Pester tests/` (all pass).
3. Manual runtime checks in `Browse-P4.ps1`:
   - Compressed mode unchanged.
   - `E` toggles expanded/collapsed reliably.
   - Expanded row shows opened/shelved/date.
   - Scrolling + scrollbar + selection remain coherent in both modes.
   - Reload and resize keep state valid.

---

## Risks and Mitigations

| Risk | Mitigation |
|---|---|
| Render/reducer geometry mismatch causes off-by-one scrolling | Centralize geometry helpers and re-use in reducer; mirror formulas in render tests.
| Extra shelved describe call slows startup or fails | Chunk calls; catch failures and default shelved counts to `0`.
| Refactor breaks existing filters | Keep `HasShelvedFiles`/`HasOpenedFiles` fields and semantics unchanged.
| Unicode glyphs may render poorly in some terminals | Keep text readable even if glyphs degrade; counts/date remain plain text.

---

## Future Nice Extensions (post-MVP)

1. Third list mode (`Compact` / `Expanded` / `Verbose`) with additional metadata rows.
2. User-configurable key bindings and persisted UI preferences.
3. Lazy shelved-count enrichment (load fast first, enrich asynchronously).
4. Optional extra detail metrics (files by action, net line count if available).
5. Server-friendly cache keyed by changelist id + update time to reduce repeated describe calls.

---

## Files Expected to Change

- `p4/Models.psm1`
- `p4/P4Cli.psm1`
- `tui/Reducer.psm1`
- `tui/Input.psm1`
- `tui/Render.psm1`
- `tests/P4Cli.Tests.ps1`
- `tests/Reducer.Tests.ps1`
- `tests/Render.Tests.ps1`
- `tests/Input.Tests.ps1` (new)
