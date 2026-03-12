# PerFourceCommanderConsole — File Browser + Filtering Plan

> Status: largely implemented.
>
> This plan has been updated to reflect the current codebase. Completed phases are
> summarized and marked [COMPLETE]. Remaining work focuses on the unfinished file
> filtering MVP and on aligning file loading with the responsive-command strategy
> described in [Plan.ResponsiveCommandExecution.md](Plan.ResponsiveCommandExecution.md).

## Current Status Summary

### [COMPLETE] Implemented foundation

- Generic state deep-copy exists via `Copy-StateObject` / `Copy-BrowserState`.
- `Ui.ScreenStack`, file cache, file cursor state, and file filter state exist.
- Reducer routing is split across changelists, files, and command output screens.
- `Runtime.ModalPrompt` replaced the older command-only modal shape.
- `Format-TruncatedDepotPath` exists with dedicated tests.

### [COMPLETE] Implemented file-browser shell

- `RightArrow` / `O` opens the Files screen from the selected changelist.
- Both pending and submitted changelists load into a shared Files screen.
- Files render in a virtualized list with a detail inspector.
- Back navigation from Files to Changelists works.
- Reload evicts the current file cache entry and re-fetches file data.

### Remaining MVP gaps

- File filter prompt and token parsing are not finished.
- `SetFileFilter` / `OpenFilterPrompt` remain stubs.
- `VisibleFileIndices` still defaults to all loaded files.
- Files status bar is useful but does not yet show the planned visible/total filtered counters.
- Opened-file loading still performs eager content-modified enrichment; this should now be aligned with the responsive-command plan by deferring or lazily computing expensive enrichment.

## Goals

1. Browse **very large file lists** (up to ~100k entries) for:
   - **Opened files in a pending changelist**
   - **Files in a submitted changelist** (same UX; different data source)
2. Keep the UI **snappy** by loading the full list once, then doing **in-memory filtering**.
3. Establish an architecture that scales to future operations:
   - Preview file contents
   - Diff
   - Revision history (filelog)
   - More Perforce operations

---

## UX Overview

### Screen hierarchy

- **Level 0 — Changelists (existing)**
  - Left: changelist filters
  - Top-right: changelist list
  - Bottom-right: changelist details (describe summary)

- **Level 1 — Files (new)**
  - Left: file filters (substring + simple facets)
  - Top-right: file list (virtualized scrolling)
  - Bottom-right: file inspector (metadata + hints)

### Navigation

- From changelists screen:
  - **RightArrow** (or `O`) → open **Files screen** for selected changelist
  - **Enter/D** remains describe/details (existing behavior)

- From files screen:
  - **LeftArrow / Esc** → back to changelists screen

---

## MVP Scope

### MVP features

1. **File list screen** with: [COMPLETE]
   - Virtualized list rendering (render only visible window)
   - Smooth scrolling: Up/Down, PageUp/PageDown, Home/End
   - Scroll thumb indicator (e.g. `▐` or `█`)
2. **Load full file list** into memory for the selected changelist. [COMPLETE]
3. **Basic filtering** [REMAINING]
   - Substring filter (case-insensitive) across path and filename
   - Optional keyword `action:<value>` (exact match) if action data exists
4. Status bar counters: [PARTIAL]
   - `📁 Files: <visible>/<total>  🔍 Filtered: <filteredCount>`
5. Minimal file inspector: [COMPLETE]
   - Full depot path
   - Action (if available)
   - Type (optional)
   - Selected index position

### Non-goals for MVP

- Autocomplete for filter tokens
- Complex query parsing (AND/OR groups, parentheses)
- Background loading / streaming results
- Preview/diff/history operations

Note:
- The original MVP treated background loading as out of scope.
- That remains true for the file-browser MVP itself, but any new enrichment work
  should now be designed to fit the staged responsive-command plan rather than
  deepening synchronous blocking behavior.

---

## Data Model

### Core entities

Define a "file entry" model that works for both opened and submitted lists:

```text
FileEntry
- DepotPath        : string  // //depot/...
- FileName         : string  // derived tail
- Action           : string? // edit/add/delete/move/add/...
- FileType         : string? // text/binary/...
- Change           : int     // changelist number
- SourceKind       : enum { Opened, Submitted }
- SearchKey        : string  // cached lowercase string for substring filtering
```

Notes:
- `FileName` is derived once for rendering and quick matching.
- `SearchKey` is precomputed once (lowercased) to avoid repeated allocations.
  - `SearchKey = (DepotPath + " " + (Action ?? "") + " " + (FileType ?? "")).ToLowerInvariant()`.
  - Includes `FileType` from the start so future `type:` facets work without cache invalidation.
- Avoid precomputing display strings (`DisplayPath`, `DisplayAction`). Virtualized lists mean you only render ~50 items per frame. Truncating and padding strings on-the-fly during render is extremely fast and handles terminal resizing correctly.

### State shape — follow existing conventions

The existing state is decomposed into `Data`, `Ui`, `Query`, `Derived`, `Cursor`, and `Runtime`. The file browser state follows the same decomposition rather than introducing a separate monolithic sub-state. This keeps `Copy-BrowserState` and `Update-BrowserDerivedState` following a single pattern.

```text
State.Ui.ScreenStack                 : string[]  // e.g. @('Changelists', 'Files')

State.Data.FileCache                  : Dict<string, FileEntry[]>
                                        keyed by "<Change>:<SourceKind>"
State.Data.FilesSourceChange          : int       // which CL is loaded
State.Data.FilesSourceKind            : string    // 'Opened' | 'Submitted'

State.Query.FileFilterTokens          : @(
    @{ Kind = 'Substring'; Value = '...' },
    @{ Kind = 'Action';    Value = '...' },
    ...
)                                       // structured token list
State.Query.FileFilterText            : string    // raw text for display

State.Derived.VisibleFileIndices      : int[]     // indices into FileCache entry

State.Cursor.FileIndex                : int       // mirrors Cursor.ChangeIndex
State.Cursor.FileScrollTop            : int       // mirrors Cursor.ChangeScrollTop
```

Design notes:
- `Ui.ScreenStack` controls navigation. The active screen is always `$State.Ui.ScreenStack[-1]`. This makes deep navigation (like opening a Diff view on top of Files) natural.
- `FileCache` is a dictionary so navigating back and forth between changelists doesn't re-fetch.
- `FileFilterTokens` is a list of typed tokens from the start, making future extensions (`type:`, `path:`, `name:`) trivial — just add a new `Kind`. Parsing and evaluation are generic loops, not if/else chains.

### Invariants

- **AllFiles is immutable once loaded.** The file list for a given `(Change, SourceKind)` is never mutated in-place. To refresh, reload fully and replace the cache entry. This means `VisibleFileIndices` (indices into AllFiles) can never go stale.
- **FilteredIndices always valid.** `Update-BrowserDerivedState` recomputes `VisibleFileIndices` from scratch on any filter or data change, clamping cursor/scroll just like it does for changelists.

---
## Perforce data acquisition

### [COMPLETE] Current implementation note

The implemented pending-file path uses `p4 fstat -Ro` rather than `p4 opened`.
This has been a good practical choice because it provides the opened-file data and
unresolved state needed by the current UI in a single stable query.

For submitted changelists, the implementation uses `p4 describe -s` and converts
the parsed files into shared `FileEntry` objects.

### MVP commands

1. **Opened files in a pending changelist**
  - Original plan: `p4 opened -c <cl> -ztag`
  - Current implementation: `p4 fstat -Ro -e <cl> -T change,depotFile,action,type,unresolved //...`
  - Result: implemented and working
2. **Submitted changelist files**
   - `p4 describe -s -ztag <cl>`
  - Parse files from `depotFileN`, `actionN`, `typeN` (if available)
  - Result: implemented and working

### Parsing approach

- Use `-ztag` and parse as a stream of `key value` pairs.
- For MVP, accept that some fields may be missing; store nulls.
- Create `FileEntry` list, compute `FileName`, `SearchKey`.

### Error handling

### [COMPLETE] Current implementation summary

- Empty pending changelists return an empty file list instead of hard-failing.
- Submitted describe parsing gracefully handles missing indexed fields.
- File lists are cached by `<Change>:<SourceKind>`.
- Reload evicts the active cache entry and forces a fresh fetch.

### Alignment with responsive-command plan

The old plan assumed synchronous side effects and noted that a late `Esc` should
cache-but-not-render the result. The newer responsive-command plan supersedes that
assumption.

Going forward:

- avoid adding new synchronous multi-step work inside the initial Files load
- prefer a fast first paint of the file list
- treat expensive enrichment as deferred or lazy work
- design any future background fetches so stale results can be ignored safely

- Empty changelist (no opened files): `p4 opened -c <cl>` returns non-zero with "file(s) not opened" when the changelist has no opened files. Use the existing `Test-IsP4NoOpenedFilesError` helper (already in `P4Cli.psm1`) — return an empty list, not an error.
- Describe parse failures: Gracefully handle missing `depotFileN` keys (already handled by the `Get-P4Describe` indexed loop).
- Load cancellation: `Invoke-BrowserSideEffect` blocks during I/O. If the user navigates away (Esc) before loading completes, the loaded data should be cached but not rendered (check `Ui.ScreenStack[-1]` after the side effect returns).
- Cache invalidation: Reloading the view (e.g. `F5` or `ReloadRequested` action) should evict the cache entry for the current `FilesSourceChange` to fetch fresh data.


### Caching

- Cache file lists in `State.Data.FileCache` keyed by `"<Change>:<SourceKind>"` for fast back/forth navigation.
- Cache the filtered indices per `(Change, SourceKind, FilterText)` (optional; can be added later).

---

## UI Layout for Files Screen

### [COMPLETE] Current implementation summary

- Left pane shows the active filter text and file-filter hints.
- Right pane renders the file list plus badges for unresolved / modified state.
- Bottom-right inspector shows file metadata, resolve state, and content-modified state.

### Remaining polish

- wire the actual filter prompt into the existing left-pane hints
- update the status bar to show visible/total counters more explicitly
- if file counts become large, consider using `Format-TruncatedDepotPath` more broadly in the list and inspector for consistently stable tail-focused rendering

### Left pane: Filters

MVP filter UI should be simple and low risk:

- “Filter:” line that shows the active query (prepend with `🔍`)
- “Hints” for syntax:
  - `text` → substring match
  - `action:add` → action exact match
  - `clear` / `Esc` to clear

Input method (MVP):
- Generalize the existing `Runtime.CommandModal` into a multi-purpose `ModalPrompt` with a `Purpose` field (`'Command'` | `'FileFilter'`). This avoids duplicating modal state and keeps the render path clean.
  - Press `/` → open modal with `Purpose = 'FileFilter'`
  - User types query, Enter applies, Esc cancels
  - Alternatively, `Spacebar` on a left-pane filter item toggles an action facet (consistent with the changelists screen UX).

Status:
- `ModalPrompt` generalization is complete.
- The `FileFilter` prompt flow is not yet wired up.

### Top-right: File list

Row format (MVP):

```text
[Icon] <Action>  <DepotPathTailOrTrimmed>
```

Rules:
- Add a column for a UTF-8 file icon:
  - Default: `📄`
  - Depending on action or type, these can be mapped (e.g. `❌` for delete, `📝` for edit, `➕` for add, etc.)
  - Or, map file extensions to icons (e.g., `.cs` → `🔷`, `.json` → `⚙️`).
- Prefer showing the **filename** prominently.
- Keep the right side stable as you scroll.
- If you truncate, truncate the **left** of the path and keep the tail, perhaps indicating truncation with `…` (U+2026).
- Define a shared `Format-TruncatedDepotPath -Path $path -MaxWidth $w` helper. This will be reused by the inspector, status bar, and future viewers (diff, filelog).

### Bottom-right: Inspector

Show:
- DepotPath (full)
- Action (if known)
- SourceKind + CL number
- Short help:
  - `[/] filter  [Esc] back  [Tab] focus`

---

## Filtering Semantics

### Status

This entire section is still the primary unfinished MVP area.

- `FileFilterTokens` exists in state.
- `SetFileFilter` currently stores raw text but does not parse or apply tokens.
- `OpenFilterPrompt` exists as an action but is still a stub.
- `VisibleFileIndices` still defaults to the full loaded file list.

### Query grammar (MVP)

A single line of text that is parsed into a **token list** (see `State.Query.FileFilterTokens`):

- Tokens matching `key:value` become typed filter tokens.
- All remaining text is joined as a single `Substring` token.

Examples:
- `DocumentManager` → `@( @{ Kind='Substring'; Value='documentmanager' } )`
- `action:add` → `@( @{ Kind='Action'; Value='add' } )`
- `action:edit DocumentManager` → `@( @{ Kind='Action'; Value='edit' }, @{ Kind='Substring'; Value='documentmanager' } )`

Rules:
- Case-insensitive (values lowered at parse time)
- `action:` matches the whole action string (exact, case-insensitive)
- `Substring` matches against `SearchKey`
- Unknown `key:` prefixes are treated as literal substring text (graceful fallback)

### Filtering algorithm (MVP)

1. Start with all indices `[0..AllFiles.Length-1]`
2. For each token in `FileFilterTokens`, filter in order:
   - `Action` → exact match on `FileEntry.Action` (case-insensitive)
   - `Substring` → `SearchKey.Contains(valueLower)`
3. Use `Sort-Object -Stable` (PowerShell 7) to preserve original depot-path order within ties.

Maintain:
- `VisibleFileIndices` as an array of ints (mirrors `VisibleChangeIds`). **Important:** Always construct this array via `Write-Output -NoEnumerate @($indices)` to avoid PowerShell pipeline unrolling bugs when reducing collections of size 1.
- Preserve selection as much as possible:
  - If previously selected item is still present, keep it selected
  - Else clamp selection to end

### Predicate registry pattern

Mirror the changelist screen's `$script:PendingFilterPredicates` pattern for file facet filters. Define predicates in an ordered dictionary so the left-pane filter panel can be added later with minimal code:

```powershell
$script:FileFilterPredicates = [ordered]@{
    'action:edit'   = { param($entry) $entry.Action -eq 'edit' }
    'action:add'    = { param($entry) $entry.Action -eq 'add' }
    # ... built dynamically from KnownActions on load
}
```

---

## Input & Keybindings (MVP)

### [COMPLETE] Current implementation summary

- Navigation actions are reused on the Files screen.
- `RightArrow` / `O` opens Files.
- `LeftArrow` / `Esc` closes Files.
- `F1` help and `F5` reload are already integrated.

### Remaining work

- `/` already maps to `OpenFilterPrompt`, but the prompt flow still needs to be implemented.

### Reuse existing action types

`ConvertFrom-KeyInfoToAction` already emits generic actions (`MoveUp`, `MoveDown`, `PageUp`, `PageDown`, `MoveHome`, `MoveEnd`, `SwitchPane`, `ToggleHelpOverlay`, etc.). The files screen should **reuse these same action types** — no new navigation actions are needed. The reducer discriminates by `$State.Ui.ScreenStack[-1]` to decide which cursor to move, just as it currently discriminates by `$State.Ui.ActivePane`.

### Files Screen

- Navigation: reuses `MoveUp`, `MoveDown`, `PageUp`, `PageDown`, `MoveHome`, `MoveEnd`
- Scrolling: `Update-BrowserDerivedState` keeps `FileScrollTop` such that `FileIndex` stays in viewport
- Focus: `Tab` (`SwitchPane`) cycles focus within the files screen
- New actions (files-screen-only):
  - `/` → `OpenFilterPrompt` — opens modal with `Purpose = 'FileFilter'`
  - `Esc` or `LeftArrow` → `CloseFilesScreen` — pops back to changelists
  - `F1` → `ToggleHelpOverlay` (reused, shows screen-specific content)

### Changelists Screen additions

- `RightArrow` or `O` → `OpenFilesScreen` action:
  - For pending: `SourceKind = 'Opened'`
  - For submitted: `SourceKind = 'Submitted'`
  - Payload: `@{ Type='OpenFilesScreen'; Change=$change; SourceKind=$kind }`

---

## Rendering & Performance Notes

### Updated guidance

The original guidance around full-load plus virtual rendering is still sound for the
base file list.

However, the newer responsive-command plan changes one important recommendation:

- keep the initial file-list load fast
- defer expensive enrichment, especially content-modified detection
- avoid expanding synchronous first-load work just because the list itself renders efficiently

So the preferred model is now:

1. load the base file list
2. render it immediately
3. enrich lazily or in a later phase when needed

### Why full-load + virtual rendering is enough

- 100k entries in memory is fine.
- Rendering is the expensive part; render only the visible window.

### Keep filtering fast

- Precompute `SearchKey` on load.
- Debounce filter typing by using modal entry (no live re-filter on every keystroke for MVP).
  - Optionally, do “apply on Enter” only.

### Avoid allocations in hot paths

- Truncate and pad dynamically in `Render.psm1` instead of doing it during the load phase. Even with 100k items, rendering ~50 items takes < 1 ms. Precomputing 100k format changes is too slow.

---

## Implementation Plan (Step-by-step)

### Step 0 — Preparatory refactors [COMPLETE]

Completed summary:

- Generic state deep-copy replaced the older boilerplate-heavy copying.
- Reducer routing is split by active screen.
- `Runtime.ModalPrompt` generalized the older command modal state.
- `Format-TruncatedDepotPath` was added in the shared helpers module.

Deliverable achieved:
- cleaner internal structure ready for the file browser

### Step 1 — Files screen skeleton [COMPLETE]

Completed summary:

- `Ui.ScreenStack` defaults to `@('Changelists')`.
- file-specific state fields were added to `Data`, `Query`, `Derived`, and `Cursor`.
- Files screen open/close navigation exists.
- the render path routes by active screen.
- Files screen navigation and back-stack behavior are covered by tests.

Deliverable achieved:
- the user can switch to the Files screen and back

### Step 2 — Pending changelist file loading [COMPLETE]

Completed summary:

- Pending changelists load opened files into `Data.FileCache['<change>:Opened']`.
- `FileEntry` objects precompute `FileName` and `SearchKey`.
- unresolved state is captured as part of the base data load.
- current implementation also enriches content-modified state eagerly.

Implementation note:
- The code uses `p4 fstat -Ro` instead of `p4 opened`, which is acceptable and currently working well.

Deliverable achieved:
- pending changelists open into a working, scrollable Files screen

### Step 3 — Submitted changelist file loading [COMPLETE]

Completed summary:

- Submitted changelists load via `p4 describe -s`.
- parsed files are converted into shared `FileEntry` objects.
- the same Files screen renders both opened and submitted file sources.

Deliverable achieved:
- submitted changelists open in the same Files screen

### Step 4 — Filter prompt and filtering (substring + action) [REMAINING]

This is the main unfinished MVP step.

Required work:

1. implement `/` → `OpenFilterPrompt` → modal with `Purpose = 'FileFilter'`
2. on Enter:
  - parse query into `FileFilterTokens`
  - support `Substring` and `Action` token kinds
  - recompute `VisibleFileIndices`
  - preserve selection if possible
3. make `Esc` inside the filter prompt cancel editing
4. support `Esc` outside the prompt to clear the active file filter
5. show the active filter summary consistently in the left pane and status bar

Alignment with responsive-command plan:

- filtering should remain fully in-memory once files are loaded
- do not add new synchronous `p4` calls as part of filter application

Deliverable target:
- users can filter by substring and/or `action:value`, and clear filters predictably

### Step 5 — Polish and responsive alignment [PARTIAL]

Already done:

- Files screen rendering is stable
- inspector details exist
- navigation and back-navigation behavior are tested

Remaining work:

1. update the status bar to show explicit visible/total filtered counters
2. verify and test selection retention after filtering
3. verify stable result ordering after filtering
4. align expensive enrichment with the responsive-command plan:
  - prefer fast first paint of the file list
  - defer or lazily compute `IsContentModified`
  - avoid growing synchronous blocking work during `LoadFiles`

Deliverable target:
- the UI feels predictable under filtering, scrolling, and screen switching
- initial file-list load remains as fast as possible

---

## Testing Plan

### [COMPLETE] Current coverage summary

- The existing codebase already has strong coverage for:
  - file-browser state shape
  - Files screen reducer behavior
  - opened and submitted file loading paths
  - file rendering and inspector rows
  - helper behavior such as depot-path truncation

### Remaining test work

- add focused tests for token parsing and in-memory file filtering
- add selection-retention tests after filter changes
- once expensive enrichment is deferred, add tests that distinguish base file loading from later enrichment

### Unit tests (Pester)

- **Parsing (P4Cli)**:
  - `p4 opened -ztag` → correct `DepotPath`, `Action`, optional `Type`
  - `p4 describe -ztag` → correct file list extraction
  - Empty changelist (no opened files) → returns empty list, no error

- **FileEntry construction**:
  - `SearchKey` includes depot path, action, and file type (lowercased)
  - `FileName` is correctly derived from depot path tail

- **Filter token parsing**:
  - `"DocumentManager"` → single Substring token
  - `"action:add"` → single Action token
  - `"action:edit DocumentManager"` → Action + Substring tokens
  - `"unknown:foo bar"` → falls back to substring for unknown key
  - Empty string → empty token list (shows all)

- **Filtering algorithm**:
  - substring only → correct subset
  - action only → correct subset
  - action + substring → intersection
  - empty filter → returns all indices
  - result order is stable (preserves depot-path order)
  - Array return preserves identity even when size=1 ($-NoEnumerate verification).

- **Reducer (Files screen)**:
  - `OpenFilesScreen` pushes `'Files'` onto `Ui.ScreenStack` and triggers load flag
  - `CloseFilesScreen` pops `'Files'` from `Ui.ScreenStack` and preserves `DetailChangeId`
  - Navigation actions (`MoveUp`/`MoveDown`/`PageUp`/`PageDown`/`Home`/`End`) clamp `FileIndex` within `VisibleFileIndices` bounds
  - `FileScrollTop` keeps selection visible after navigation
  - `SetFileFilter` recomputes `VisibleFileIndices` and preserves selection if possible
  - Resize recalculates layout for files screen
  - Back-from-files restores changelist cursor position

- **`Copy-BrowserState` round-trip**:
  - Verify that the generic state copy logic properly replicates all primitive, array, hashset, and nested object fields without missing details.

### Shared utility tests

- `Format-TruncatedDepotPath`:
  - Path shorter than max width → returned as-is
  - Path longer than max width → left-truncated with ellipsis, filename preserved
  - Edge cases: empty path, width = 1

### Snapshot-ish render tests (optional)

- Render a small Files screen with known data and verify key lines exist.
- Validate trimming strategy keeps filename visible.

---

## Future Ideas (Post-MVP)

### Alignment with responsive-command plan

The newer responsive-command plan changes the priority of some future ideas:

- lazy enrichment is now preferred over eager enrichment
- background or staged enrichment is a better fit than adding more blocking work to initial file loads
- future preview / diff / history viewers should be designed to plug into the same responsive command orchestration rather than directly extending synchronous side effects

### 1) Screen stack for deep navigation

[COMPLETE] Moved into MVP and implemented via `Ui.ScreenStack`.

### 2) Autocomplete for filter tokens

- When filter prompt is open:
  - Suggest keys: `action:`, `type:`, `state:`, `path:`, `name:`
  - If cursor is after `action:`, suggest known actions from the dataset.
- Implementation:
  - maintain a `FacetIndex` built on load:
    - `KnownActions = distinct(AllFiles.Action)`
  - overlay a small suggestion list below the prompt

### 3) Facet panel (checkbox filters) in left pane

- Show groups:
  - Action (multi-select)
  - Type
  - State (unresolved, moved, etc.)
- AND across groups, OR within group.
- Reuse the predicate registry pattern from the changelist filters.
- Allow `Spacebar` toggling on left-pane items (matches changelist UX).

### 4) "Find next match" navigation

- With an active substring filter:
  - `n` jumps to next match (or next match within unfiltered list)
  - `N` previous

### 5) Preview / Diff / History operations (modal viewers)

- `F3` preview (p4 print)
- `F4` diff
- `H` history (p4 filelog)
Each opens a scrollable full-screen viewer overlay (screen stack makes this natural).

### 6) `fstat` enrichment as a lazy decorator

- Model as `Enrich-FileEntries -Entries $entries -Fields @('headAction','unresolved')` that augments entries in-place.
- Keep enrichment orthogonal to filtering.
- Lazy evaluation: compute only when user enables those filters or navigates to the inspector.
- Includes:
  - unresolved detection (resolve -n / fstat flags)
  - moved detection (action:move/add, move/delete)

### 7) Operation palette

- A single key (e.g., `.`) opens a palette:
  - Preview, Diff, History, Copy path, etc.
- Keeps keybindings from exploding as features grow.

### 8) Persistent per-screen filters

- Remember last filter text for:
  - Opened files
  - Submitted files
- Optionally remember per workspace / per stream.

### 9) Generic deep-copy for state

[COMPLETE] Implemented as part of the MVP preparatory refactor phase.

---

## Deliverables Checklist

MVP complete when:

- [x] Preparatory refactors done (reducer split, modal generalization, round-trip test)
- [x] Files screen opens from changelist selection (RightArrow / O)
- [x] Full file list loads (opened + submitted) with error handling
- [x] Virtual scrolling works smoothly with precomputed display fields
- [ ] `/` filter prompt applies substring + `action:` filters (token-list parsing)
- [ ] Counts shown in status bar
- [x] Back navigation restores changelist screen (cursor, detail pane preserved)
- [ ] All new Pester tests pass for the remaining filtering work
- [ ] PSScriptAnalyzer clean after the remaining filtering work

## Recommended Close-Out Plan

This plan should remain open until the remaining filtering MVP is finished.

Recommended final sequence:

1. implement file-filter prompt and token parsing
2. compute filtered `VisibleFileIndices` in-memory
3. update Files status bar counters
4. defer or lazily compute expensive modified-content enrichment to align with [Plan.ResponsiveCommandExecution.md](Plan.ResponsiveCommandExecution.md)
5. add focused Pester coverage for filtering and selection retention

Once those items are complete, this plan can be closed and treated as fully superseded by the responsive-command follow-up plan for future file-browser evolution.
