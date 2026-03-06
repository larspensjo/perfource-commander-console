# PerFourceCommanderConsole — File Browser + Filtering Plan

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

1. **File list screen** with:
   - Virtualized list rendering (render only visible window)
   - Smooth scrolling: Up/Down, PageUp/PageDown, Home/End
   - Scroll thumb indicator (e.g. `▐` or `█`)
2. **Load full file list** into memory for the selected changelist.
3. **Basic filtering**
   - Substring filter (case-insensitive) across path and filename
   - Optional keyword `action:<value>` (exact match) if action data exists
4. Status bar counters:
   - `📁 Files: <visible>/<total>  🔍 Filtered: <filteredCount>`
5. Minimal file inspector:
   - Full depot path
   - Action (if available)
   - Type (optional)
   - Selected index position

### Non-goals for MVP

- Autocomplete for filter tokens
- Complex query parsing (AND/OR groups, parentheses)
- Background loading / streaming results
- Preview/diff/history operations

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

### MVP commands

1. **Opened files in a pending changelist**
   - `p4 opened -c <cl> -ztag` (preferred for stable parsing)
   - Parse `... depotFile`, `... action`, optional `... type`
2. **Submitted changelist files**
   - `p4 describe -s -ztag <cl>`
   - Parse files from `depotFileN`, `actionN`, `typeN` (if available)

### Parsing approach

- Use `-ztag` and parse as a stream of `key value` pairs.
- For MVP, accept that some fields may be missing; store nulls.
- Create `FileEntry` list, compute `FileName`, `SearchKey`.

### Error handling

- Empty changelist (no opened files): `p4 opened -c <cl>` returns non-zero with "file(s) not opened" when the changelist has no opened files. Use the existing `Test-IsP4NoOpenedFilesError` helper (already in `P4Cli.psm1`) — return an empty list, not an error.
- Describe parse failures: Gracefully handle missing `depotFileN` keys (already handled by the `Get-P4Describe` indexed loop).
- Load cancellation: `Invoke-BrowserSideEffect` blocks during I/O. If the user navigates away (Esc) before loading completes, the loaded data should be cached but not rendered (check `Ui.ScreenStack[-1]` after the side effect returns).
- Cache invalidation: Reloading the view (e.g. `F5` or `ReloadRequested` action) should evict the cache entry for the current `FilesSourceChange` to fetch fresh data.


### Caching

- Cache file lists in `State.Data.FileCache` keyed by `"<Change>:<SourceKind>"` for fast back/forth navigation.
- Cache the filtered indices per `(Change, SourceKind, FilterText)` (optional; can be added later).

---

## UI Layout for Files Screen

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

### Step 0 — Preparatory refactors

1. **Implement Generic Generic Deep-Copy for State.** Replace the boilerplate heavy `Copy-BrowserState` function with a generic implementation that deep copies generic `PSObject.Properties`, correctly handling types such as `HashSet` and `Dictionary`. This satisfies DRY and prevents missing-field class of state bugs.
2. **Split the reducer.** Extract a thin `Invoke-BrowserReducer` router that dispatches to `Invoke-ChangelistReducer` (existing logic) or `Invoke-FilesReducer` (new) based on `$State.Ui.ScreenStack[-1]`. This prevents the switch block from doubling in size.
3. **Generalize `Runtime.CommandModal` → `Runtime.ModalPrompt`.** Add a `Purpose` field (`'Command'` | `'FileFilter'`). Rename throughout. The filter modal reuses this mechanism.
4. **Add `Format-TruncatedDepotPath` utility** in a shared helpers module.

Deliverable:
- No user-visible change; cleaner internal structure ready for file browser.

### Step 1 — Add "Files screen" skeleton

1. Add `Ui.ScreenStack = @('Changelists')` default to `New-BrowserState`.
2. Add file-related defaults to state: `Data.FileCache = @{}`, `Query.FileFilterTokens = @()`, `Query.FileFilterText = ''`, `Derived.VisibleFileIndices = @()`, `Cursor.FileIndex = 0`, `Cursor.FileScrollTop = 0`.
3. Add reducer actions in `Invoke-FilesReducer`:
   - `OpenFilesScreen` — pushes `'Files'` onto `Ui.ScreenStack`, triggers load side-effect flag, and optionally clears previous file filter text.
   - `CloseFilesScreen` — pops `'Files'` from `Ui.ScreenStack`, preserves `DetailChangeId`
   - `SetFileFilter` — parses text into token list, recomputes `VisibleFileIndices`
4. Extend `Update-BrowserDerivedState` to compute `VisibleFileIndices` when on files screen. **Remember the array-as-value rule using `-NoEnumerate`!**
5. Route navigation actions (`MoveUp`/`MoveDown`/etc.) to file cursor when active screen is `'Files'`.
6. Update the main loop to route render function based on `Ui.ScreenStack[-1]`.

Deliverable:
- You can switch to the Files screen and back, with placeholder content.

### Step 2 — Load file list for pending changelist (Opened)

1. Implement side effect for `OpenFilesScreen` (Opened):
   - Call `p4 opened -c <cl> -ztag`
   - Use `Test-IsP4NoOpenedFilesError` for empty CLs
   - Parse into `FileEntry[]`
2. Precompute `SearchKey`, `FileName`, `DisplayPath`, `DisplayAction`.
3. Store in `Data.FileCache['<change>:Opened']`.
4. Initialize `VisibleFileIndices = all`, default cursor/scroll.

Deliverable:
- File list appears for pending CLs and can scroll.

### Step 3 — Add `describe`-based file list for submitted changelist

1. Implement side effect for `OpenFilesScreen` (Submitted):
   - Call `p4 describe -s -ztag <cl>`
   - Parse file entries (reuse existing `Get-P4Describe` files extraction)
2. Store in `Data.FileCache['<change>:Submitted']`.
3. Reuse the same Files screen and filtering logic.

Deliverable:
- Submitted CLs open the same Files screen with file list.

### Step 4 — Add filter prompt and filtering (substring + action)

1. Add `/` key → `OpenFilterPrompt` action → opens modal with `Purpose = 'FileFilter'`.
2. On Enter:
   - Parse query into `FileFilterTokens` (token list with `Substring` and `Action` kinds)
   - Recompute `VisibleFileIndices`
   - Preserve selection if item still visible; else clamp
3. `Esc` in modal cancels; `Esc` outside modal clears filter.
4. Show active filter summary in left pane and status bar.

Deliverable:
- Users can filter by substring and/or `action:value`, and clear filters.

### Step 5 — Polish: status counts + stable selection + rendering

1. Status bar:
   - total count, filtered count, selected index / percent
2. Selection retention:
   - preserve selection item if still present after filtering
3. Verify `Sort-Object -Stable` preserves original depot-path order.
4. Test back-navigation restores changelist cursor and detail pane.

Deliverable:
- The UI feels predictable under filtering, scrolling, and screen switching.

---

## Testing Plan

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

### 1) Screen stack for deep navigation

(Moved to MVP phase to prevent future rewrite overhead).

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

(Moved to MVP Pre-Refactor phase to ensure reliable state copying and satisfy UDF principles).

---

## Deliverables Checklist

MVP complete when:

- [ ] Preparatory refactors done (reducer split, modal generalization, round-trip test)
- [ ] Files screen opens from changelist selection (RightArrow / O)
- [ ] Full file list loads (opened + submitted) with error handling
- [ ] Virtual scrolling works smoothly with precomputed display fields
- [ ] `/` filter prompt applies substring + `action:` filters (token-list parsing)
- [ ] Counts shown in status bar
- [ ] Back navigation restores changelist screen (cursor, detail pane preserved)
- [ ] All new Pester tests pass
- [ ] PSScriptAnalyzer clean
