# PerFourceCommanderConsole — Unresolved Conflict Indicators and Pending Filter Plan

## Purpose

This document proposes a detailed implementation plan for three related features:

1. Show a shared unresolved-conflict glyph on **opened files** that still need resolve.
2. Show the same glyph on **pending changelists** that contain one or more unresolved files.
3. Add a **pending changelist filter** that shows only changelists with unresolved files.

The plan is intentionally aligned with the project rules in `docs/Agents.md`:

- preserve **Unidirectional Data Flow**
- keep reducers pure
- avoid duplicated logic
- avoid naked constants
- prefer **Correctness by Construction**
- add tests that lock in behavior and contracts

This plan is for review before implementation.

---

## Confirmed product decisions

These decisions are assumed for this plan:

1. The unresolved glyph is **`⚠`**.
   - Use the plain text form, not the emoji presentation variant, to reduce terminal width inconsistencies.
2. The glyph is shown for:
   - files on the **Files** screen when the file is unresolved
   - pending changelists on the **Changelists** screen when the changelist has at least one unresolved file
3. The new changelist filter applies only to **Pending** view mode.
4. Submitted changelists do **not** participate in unresolved-file decoration for this feature.
5. The implementation should use **structured `p4 fstat` data**, not ad hoc parsing of `p4 resolve -n` output.
6. The current scope does **not** add explicit UI support for the Perforce `default` changelist.
   - If workspace-wide unresolved queries return records for `change: 0`, those records should be ignored for changelist-level decoration until the `default` changelist is intentionally represented in the UI.

---

## Why `p4 fstat` is the right command

### Primary data source

Use `p4 fstat`, because it exposes unresolved state directly and is easy to parse in the current JSON/tagged wrapper.

Relevant fields already documented by P4:

- `change`
- `depotFile`
- `unresolved`

Relevant options:

- `-Ro` — limit to files open in the current workspace
- `-Ru` — limit to open files that are unresolved
- `-e <change>` — limit to files affected by a changelist
- `-T ...` — request only required fields

### Command choices

#### For pending changelist enrichment

Use one workspace-wide query:

```text
p4 fstat -Ro -Ru -T change,depotFile,unresolved
```

Why:

- one call enriches the entire pending changelist list
- avoids N-per-changelist queries
- aligns with the current pending-changelist scope (current workspace)
- naturally supports `UnresolvedFileCount` aggregation by changelist

#### For opened files in one changelist

Use one changelist-scoped query:

```text
p4 fstat -Ro -Ru -e <cl> -T depotFile,unresolved
```

Why:

- returns exactly the unresolved subset for the currently opened changelist
- lets the file list be decorated without changing the existing `p4 opened -c <cl>` source of truth for file ordering and action/type data

### Why not use `p4 resolve -n`

`p4 resolve -n -c <cl>` is useful as a human diagnostic, but not as the primary UI data source.

Reasons:

- output is more presentation-oriented
- parsing is more fragile than `fstat`
- it does not fit as cleanly into the existing `Invoke-P4` → object parsing flow
- `fstat` already provides the unresolved count and integrates better with future enrichment

`p4 resolve -n` can remain a manual verification tool, but not the planned implementation path.

---

## Current architecture summary

The existing design already has the right extension points:

- `p4/Models.psm1`
  - owns UI-facing entry shapes such as `ChangelistEntry` and `FileEntry`
- `p4/P4Cli.psm1`
  - owns Perforce command execution and parsing
- `PerfourceCommanderConsole.psm1`
  - orchestrates side effects and file-screen loads
- `tui/Filtering.psm1`
  - owns pending/submitted filter predicate registries
- `tui/Render.psm1`
  - owns row decoration and inspector rendering

This means the feature should be implemented as:

1. **new parsed data** in the P4 layer
2. **new state fields** in entry objects
3. **new rendering rules** in the view layer
4. **new filter predicate** in pending filtering

That keeps the change compositional and avoids bolting special cases into reducers.

---

## Design principles for this feature

### 1) Single source of truth for unresolved state

Do not infer unresolved state in multiple places.

Instead:

- changelist unresolved state must be derived from parsed unresolved-file counts
- file unresolved state must be stored on the `FileEntry` itself before render

Render and filtering should consume those fields, never recompute them.

### 2) Shared constants, no naked constants

The unresolved glyph and related labels must be defined once and reused.

This plan now recommends using this feature as the trigger for a **broader UI glyph unification**, rather than introducing a one-off constant accessor just for unresolved state.

Why this is better:

- `tui/Render.psm1` already has top-level glyph variables for cursor, mark, and scrollbars
- adding a second constant mechanism just for unresolved state would split the single source of truth
- a unified glyph/label registry is a better base for future theming and ASCII fallback support

Minimum shared values needed for this feature:

- `Glyphs.Cursor`
- `Glyphs.Mark`
- `Glyphs.Unresolved`
- `Labels.FilterPendingUnresolved`

Because these values are needed across more than one file, they should not be repeated as raw literals throughout the codebase.

### 3) Pure parser helpers where possible

Add small pure functions that convert `p4 fstat` records into:

- `Dictionary[int,int]` for unresolved file counts by changelist
- `HashSet[string]` or dictionary for unresolved depot paths inside one changelist

This reduces duplicated parsing and makes testing straightforward.

### 4) No reducer-side I/O

All `p4` calls remain outside reducers.

Reducers should only react to already-enriched entries.

---

## Proposed shared constants strategy

To satisfy the project rule about avoiding repeated constants, introduce a shared UI theme source and gradually migrate existing glyph constants to it.

Preferred design:

- create a dedicated [tui/Theme.psm1](tui/Theme.psm1) module
- store a module-scoped cached theme object there
- import that module from the render and filtering layers

Recommended shape:

```powershell
$script:BrowserUiTheme = [pscustomobject]@{
   Glyphs = [pscustomobject]@{
      Cursor     = [char]0x25B6  # ▶
      Mark       = [char]0x25CF  # ●
      Unresolved = '⚠'
   }
   Labels = [pscustomobject]@{
      FilterPendingUnresolved = 'Has unresolved files'
   }
}

function Get-BrowserUiTheme {
   return $script:BrowserUiTheme
}
```

Why this is preferable:

- avoids duplicating glyph and label text across `Render.psm1`, `Filtering.psm1`, and tests
- unifies the old and new glyph sources instead of creating parallel mechanisms
- avoids repeated allocation from building a fresh theme object on every call
- creates a clean path for future theming or ASCII fallback without re-touching all render code

Fallback if a new module file feels too heavy:

- keep the cached theme object in [tui/Helpers.psm1](tui/Helpers.psm1)
- but still make it a cached module-scoped object, not a function that constructs a new object every time

Implementation note:

- if a new [tui/Theme.psm1](tui/Theme.psm1) file is added, update [PerfourceCommanderConsole.psd1](PerfourceCommanderConsole.psd1) accordingly
- also update module import wiring so the new theme source is loaded explicitly

The important point is not the exact file name, but that **all** UI glyphs move toward one shared, cached source of truth.

---

## Data model changes

## 1) Extend `ChangelistEntry`

Update `ConvertTo-ChangelistEntry` in `p4/Models.psm1` to include:

```text
HasUnresolvedFiles : bool
UnresolvedFileCount: int
```

Semantics:

- `HasUnresolvedFiles = ($UnresolvedFileCount -gt 0)`
- default for existing callers: `0` / `$false`

This makes changelist filtering and rendering consume one stable model.

## 2) Extend `FileEntry`

Update `New-P4FileEntry` in `p4/Models.psm1` to include:

```text
IsUnresolved : bool
```

Semantics:

- `IsUnresolved` is the single source of truth for file-level unresolved state
- default values for submitted files and ordinary opened-file creation:
   - `IsUnresolved = $false`

Why a single boolean is preferable here:

- at the individual file level, unresolved state is effectively binary for UI purposes
- the meaningful aggregation is at the changelist level, where `UnresolvedFileCount` remains useful
- it keeps the `FileEntry` shape smaller and easier to reason about

This allows file-row rendering and the inspector to remain simple.

### `SearchKey` future-proofing

Extend `SearchKey` construction so unresolved files include an extra token such as `unresolved`.

That gives a low-cost path to future file filtering features without cache invalidation.

---

## P4 layer changes

## 1) Add pure unresolved-count conversion helper

Add a pure helper in `p4/P4Cli.psm1`, similar in style to the existing opened/shelved count helpers.

Recommended function:

```text
ConvertFrom-P4FstatUnresolvedRecordsToFileCounts
```

Input:

- array of `p4 fstat` records

Output:

- `Dictionary[int,int]` mapping changelist number → unresolved file count

Behavior:

- ignore records that do not have a usable `change`
- treat each record as one unresolved open file
- increment count per changelist

This helper is the safest foundation for changelist enrichment.

## 2) Add workspace-wide unresolved count query

Add a new public function in `p4/P4Cli.psm1`:

```text
Get-P4UnresolvedFileCounts
```

Suggested behavior:

- run `p4 fstat -Ro -Ru -T change,depotFile,unresolved`
- return a `Dictionary[int,int]`
- if there are no unresolved files, return an empty dictionary
- follow the same graceful-empty pattern already used for opened/shelved helpers

Robustness requirement:

- reuse an existing shared `no such file(s)` classifier if the error text is identical to the already-handled opened-files case
- otherwise add a dedicated helper such as `Test-IsP4NoUnresolvedFilesError`
- treat the known empty-result `p4 fstat` error mode as a normal empty result, not as a UI error
- specifically normalize the `no such file(s)` / equivalent empty-unresolved condition to an empty dictionary

Graceful degradation requirement:

- if the unresolved-count query fails for reasons other than the known empty-result branch, do **not** block pending changelist loading
- instead, degrade to an empty unresolved-count dictionary and allow the changelist list to load with zero unresolved badges
- record the failure in command/output logging as usual, but do not make unresolved enrichment a hard dependency for listing pending changelists

This function should be used by pending changelist loading.

## 3) Add changelist-scoped unresolved path query

Add another function in `p4/P4Cli.psm1`:

```text
Get-P4UnresolvedDepotPaths -Change <cl>
```

Suggested behavior:

- run `p4 fstat -Ro -Ru -e <cl> -T depotFile,unresolved`
- return a case-insensitive `HashSet[string]` keyed by depot path, using `[System.StringComparer]::OrdinalIgnoreCase`
- if the changelist has no unresolved files, return an empty set

Why a set is ideal:

- enrichment becomes O(1) membership tests by `DepotPath`
- avoids array scanning during file-entry annotation
- case-insensitive membership is safer on Windows-heavy workflows and avoids fragile casing mismatches

Robustness requirement:

- use the same `Test-IsP4NoUnresolvedFilesError` empty-result handling here
- return an empty set on the known empty-unresolved branch

Typing note:

- keep the parameter as `[int] $Change` for consistency with the rest of the current P4 layer
- if explicit `default` changelist support is added later, expand the parameter shape then as a focused follow-up change rather than introducing stringly-typed parameters now

## 4) Keep `Get-P4OpenedFiles` focused

Do **not** overload `Get-P4OpenedFiles` with multi-purpose enrichment logic unless it remains compositional.

Preferred approach:

- keep `Get-P4OpenedFiles` responsible for opened file metadata (`DepotPath`, `Action`, `FileType`, `Change`)
- enrich unresolved state in a small, explicit helper

Recommended helper:

```text
Set-P4FileEntriesUnresolvedState
```

Behavior:

- takes file entries and unresolved depot-path set
- returns **new** enriched entries using `New-P4FileEntry`, rather than mutating existing entry objects in place

Implementation note:

- prefer explicit PowerShell 7 typing while enriching, such as `[bool]` and `[int]`, so entry fields do not silently drift into string or `$null` states
- prefer immutable reconstruction over post-hoc mutation, so every `FileEntry` has a complete stable shape by construction

This is clearer than embedding `fstat` calls inside basic file parsing.

---

## Pending changelist loading changes

Update `Get-P4ChangelistEntries` in `p4/P4Cli.psm1`.

### Current flow

Today it loads:

- pending changelists
- opened counts
- shelved counts

and then calls `ConvertTo-ChangelistEntry`.

### Planned flow

Extend it to also load:

- unresolved counts via `Get-P4UnresolvedFileCounts`

Then pass `UnresolvedFileCount` into `ConvertTo-ChangelistEntry`.

### Result

Every pending changelist entry will carry:

- `OpenedFileCount`
- `ShelvedFileCount`
- `UnresolvedFileCount`
- `HasOpenedFiles`
- `HasShelvedFiles`
- `HasUnresolvedFiles`

This is the correct place to compute changelist-level unresolved state, because it is already the aggregation point for other count-based badges.

---

## Files screen loading changes

Update the opened-files branch in `Invoke-BrowserFilesLoad` in `PerfourceCommanderConsole.psm1`.

### Current flow

Today the flow is:

1. `Get-P4OpenedFiles -Change $Change`
2. store entries in `State.Data.FileCache[$CacheKey]`

### Planned flow

Change it to:

1. `Get-P4OpenedFiles -Change $Change`
2. `Get-P4UnresolvedDepotPaths -Change $Change`
3. enrich the loaded file entries with unresolved state
4. store the enriched entries in `State.Data.FileCache[$CacheKey]`

Preferred enrichment shape:

- reconstruct entries through `New-P4FileEntry -IsUnresolved ...`
- do not add unresolved properties later through dynamic mutation if it can be avoided

### Submitted files

Submitted file lists should continue to create `FileEntry` objects with:

- `HasUnresolved = $false`
- `UnresolvedCount = 0`

No unresolved glyph is shown for submitted file lists in this feature.

---

## Filtering changes

## 1) Add a pending filter predicate

Update `$script:PendingFilterPredicates` in `tui/Filtering.psm1` with a new predicate:

```text
Has unresolved files
```

Recommended predicate:

```powershell
{ param($entry) [bool]$entry.HasUnresolvedFiles }
```

Fixture note:

- update existing pending-filter test fixtures so they explicitly set `HasUnresolvedFiles = $false`
- do not rely on `$null` implicitly behaving like `$false`

### Why this fits cleanly

The pending filter system is already predicate-based and ordered.

Adding the filter here automatically plugs into:

- `Get-AllFilterNames`
- `Test-EntryMatchesFilter`
- `Get-VisibleChangeIds`

No new filtering mechanism is needed.

## 2) Filter semantics

The filter should behave like the existing pending filters:

- it is additive with other selected filters
- it participates in the same AND semantics as the other pending filters
- if combined with contradictory filters, empty results are acceptable

Examples:

- `Has unresolved files` → only changelists with unresolved files
- `Has unresolved files` + `No shelved files` → unresolved changelists that also have no shelved files
- `Has unresolved files` + `No opened files` → likely empty, which is acceptable and consistent

## 3) Filter label ownership

Do not hardcode the label text separately in tests and render logic.

The same shared constant/provider should define the display label.

---

## Rendering changes — pending changelists

## 1) Add unresolved badge column to changelist rows

Update `Build-ChangeSegments` in `tui/Render.psm1`.

### Current row structure

Today the row includes:

- cursor marker
- mark badge
- change id
- optional user
- title

### Planned row structure

Add a stable unresolved badge column near the front:

```text
<cursor> <mark> <unresolved> <id> <title>
```

For example:

```text
▶ ● ⚠ 12345 Fix merge issue
▶ ●   12346 Cleanup docs
```

Why a dedicated column is best:

- stable alignment
- easy scanning in large lists
- consistent with the existing mark badge approach
- avoids burying the signal inside the title text

### Colors

Recommended:

- unresolved glyph color: `Yellow`
- when absent: reserve the same width with a blank space in `DarkGray` or neutral color
- focused row background behavior remains unchanged

Recommended related constant:

- `UnresolvedBadgeWidth = 2`
   - one glyph slot plus one trailing space
   - keeps alignment stable in render logic and tests

The glyph should remain visible even on selected rows.

## 2) Add unresolved count to changelist detail segments

Update `Build-ChangeDetailSegments` in `tui/Render.psm1`.

Current detail row already shows:

- opened count
- shelved count
- date

Extend it to also show:

- unresolved count with the same `⚠` glyph

Example:

```text
📁 12  📦 3  ⚠ 2  2026-03-09
```

Why:

- makes the aggregate count visible without entering the files screen
- keeps badge semantics consistent between row and detail pane

## 3) Expanded changelist view

If the expanded changelist row mode has extra summary content, unresolved state should be included there as well if practical.

The guiding rule is: unresolved state should be visible in the same places where opened/shelved state is already surfaced.

---

## Rendering changes — files screen

## 1) Add unresolved badge column to file rows

Update the file-row construction inside `Build-FilesScreenFrame` in `tui/Render.psm1`.

### Current row structure

Today it is roughly:

```text
<cursor> <action> <filename>
```

### Planned row structure

Change it to:

```text
<cursor> <unresolved> <action> <filename>
```

Example:

```text
▶ ⚠ edit       Foo.cs
▶   add        NewFile.cs
```

Why:

- same glyph, same meaning across screens
- small layout cost
- stable alignment with minimal row churn

## 2) Add unresolved status to inspector

Update the file inspector section in `Build-FilesScreenFrame`.

Before adding the new `Resolve:` line, refactor the inspector from the current row-index `switch` form into an array-of-lines model.

Why this refactor is recommended first:

- the current inspector logic is index-fragile
- adding one more row today increases future maintenance cost
- an array-of-lines structure makes later additions safe and obvious

Recommended new line:

- `Resolve: unresolved` when unresolved
- `Resolve: clean` otherwise

Example:

```text
File: Foo.cs
Action: edit
Type: text
Change: 12345
Source: Opened
Resolve: unresolved

//depot/main/Foo.cs
```

Why:

- gives explicit meaning to the glyph
- helps accessibility and discoverability
- keeps future `state:unresolved` filtering easy to explain

---

## State and reducer impact

This feature should require little or no reducer complexity increase.

### Expected reducer impact

- no new unresolved-specific reducer actions are required
- existing reload / file-load actions can remain unchanged in structure
- reducers simply consume enriched entry data already present in state

This is desirable and consistent with UDF.

### State shape impact

No top-level browser state fields are required beyond the new entry properties.

That is preferable to adding a parallel unresolved-cache structure immediately.

### Cache behavior

- `State.Data.FileCache` should store already-enriched `FileEntry` objects
- changelist unresolved state should be recomputed on normal changelist reload
- `Get-P4ChangelistEntries` should short-circuit before unresolved enrichment if there are zero pending changelists, so no unnecessary `p4 fstat` call is made

This keeps cache semantics straightforward.

---

## Test plan

The project instructions explicitly require locking behavior in tests.

## 1) P4 CLI unit tests

Update `tests/P4Cli.Tests.ps1`.

Add tests for:

### Unresolved count parsing

- converts `fstat` records into per-changelist unresolved counts
- aggregates multiple files in the same changelist
- ignores records missing `change`
- returns empty dictionary for empty input

### `Get-P4UnresolvedFileCounts`

- returns correct counts from mocked `Invoke-P4`
- returns empty dictionary when no unresolved files exist
- returns empty dictionary on the specific `no such file(s)` empty-result error branch
- degrades to empty dictionary on non-empty-branch failures when pending changelist loading should continue
- rethrows unexpected errors

### `Get-P4UnresolvedDepotPaths`

- returns a set containing the correct depot paths
- returns empty set when changelist has no unresolved files
- returns empty set on the specific `no such file(s)` empty-result error branch
- handles duplicate file records defensively
- uses case-insensitive membership semantics for depot paths

### `Export-ModuleMember`

- the new P4 helper functions are explicitly added to the export list in [p4/P4Cli.psm1](p4/P4Cli.psm1)

### Empty-result classifier

- recognizes the specific `p4 fstat -Ru` empty-result error text
- does not swallow unrelated `p4` failures

### File-entry enrichment

- marks matching `DepotPath` entries as unresolved
- leaves non-matching entries clean
- preserves existing `Action`, `FileType`, `Change`, `SourceKind`
- preserves `SearchKey` semantics, including the optional unresolved token
- handles path casing differences without false negatives

### `Get-P4ChangelistEntries`

- populates `UnresolvedFileCount`
- populates `HasUnresolvedFiles`
- keeps opened/shelved counts unchanged

## 2) Filtering tests

Update `tests/Filtering.Tests.ps1`.

Add tests for:

- pending filter registry contains `Has unresolved files`
- filter matches entries where `HasUnresolvedFiles = $true`
- filter excludes entries where `HasUnresolvedFiles = $false`
- combined filter behavior remains AND-based
- legacy fixtures are updated to set `HasUnresolvedFiles = $false` explicitly

## 3) Render tests

Update `tests/Render.Tests.ps1`.

Add tests for:

### Changelist rows

- unresolved changelist row shows `⚠`
- clean changelist row reserves the column without showing the glyph
- focused unresolved row still shows the glyph
- marked + unresolved row shows both badges correctly

### Changelist detail row

- unresolved count appears with glyph next to opened/shelved counts

### File rows

- unresolved file row shows `⚠`
- clean file row does not show the glyph
- selected unresolved file row still shows the glyph
- row width remains stable regardless of unresolved state

### File inspector

- unresolved file shows `Resolve: unresolved`
- clean file shows `Resolve: clean`

## 4) Browser integration tests

Update `tests/Browser.Integration.Tests.ps1` as needed.

Add or adjust tests to ensure:

- pending changelist reload keeps working when unresolved counts are added
- opening a files screen for a pending changelist stores enriched file entries in `FileCache`
- the new pending filter can be selected and affects visible changelist IDs
- submitted changelist loading remains free of unresolved decoration
- `change: 0` unresolved records do not accidentally decorate a non-existent pending changelist entry

## 5) Validation execution rules

Per `docs/Agents.md`, Pester validation should be run from a terminal, not from the editor-integrated test runner.

That means the implementation phase should explicitly validate via terminal-based `pwsh` commands only.

---

## Implementation phases

## Phase 1 — Shared constants and model scaffolding

1. Add shared UI theme/constants provider.
2. Extend `ChangelistEntry` and `FileEntry` shapes with unresolved fields.
3. Update or add model-level tests.

**Goal:** create the stable data contract first.

## Phase 2 — P4 unresolved parsing helpers

1. Add pure conversion helper for unresolved `fstat` records.
2. Add `Get-P4UnresolvedFileCounts`.
3. Add `Get-P4UnresolvedDepotPaths`.
4. Decide whether the empty-result classifier is shared or dedicated.
5. Add tests for empty and error cases.

**Goal:** isolate the risky command/parsing work before touching rendering.

## Phase 3 — Pending changelist enrichment

1. Extend `Get-P4ChangelistEntries` to include unresolved counts.
2. Extend pending filter registry with `Has unresolved files`.
3. Add filtering tests.

**Goal:** make changelist data complete before adding UI badges.

## Phase 4 — File-entry enrichment

1. Enrich opened file entries during `Invoke-BrowserFilesLoad`.
2. Keep submitted file entries explicitly clean.
3. Prefer immutable reconstruction of `FileEntry` objects rather than in-place mutation.
4. Add integration tests around cached entries.

**Goal:** make file data complete before adding file-row decoration.

## Phase 5 — Render unresolved glyphs and counts

1. Add unresolved badge column to changelist rows.
2. Add unresolved count to changelist detail segments.
3. Refactor file inspector row construction from `switch` to array-indexed lines.
4. Add unresolved badge column to file rows.
5. Add resolve-state line to file inspector.
6. Add render tests.

**Goal:** surface the feature in the UI once the data is already trustworthy.

## Phase 6 — Regression pass and cleanup

1. Run analyzer.
2. Run targeted tests, then full test suite.
3. Remove any duplicated label/glyph literals that slipped in.
4. Verify terminal width remains stable with UTF-8 glyphs.

**Goal:** finish with robustness, not just visible functionality.

---

## Risks and mitigations

## Risk 1 — duplicated unresolved logic

If unresolved detection is implemented separately for changelists and files, the two views can drift.

### Mitigation

- use shared `fstat`-based helpers
- store resolved results on entry objects
- render from entry properties only

## Risk 2 — per-changelist performance regression

If pending changelists are enriched by running one `p4` call per changelist, load time will degrade badly.

### Mitigation

- use a single workspace-wide unresolved-count query for pending changelists

## Risk 3 — terminal glyph width issues

Some terminals treat emoji-style symbols as double-width.

### Mitigation

- use plain `⚠`
- keep a dedicated fixed-width badge column
- cover alignment in render tests where practical

## Risk 4 — constant drift between code and tests

If the glyph or label is repeated across code and tests, future edits will become brittle.

### Mitigation

- centralize shared UI constants
- reuse helpers in tests where possible

## Risk 5 — empty-result edge cases from `fstat`

`p4 fstat -Ru` may legitimately return no records.

### Mitigation

- normalize empty output and known empty-result stderr branches to empty dictionary / empty set
- treat “no unresolved files” as normal, not exceptional

## Risk 6 — depot path casing mismatches

If unresolved depot paths and opened-file depot paths differ only by case, a case-sensitive lookup can silently fail to decorate the file row.

### Mitigation

- use a case-insensitive `HashSet[string]` for unresolved depot paths
- test enrichment against mixed-case path inputs

## Risk 7 — split glyph registries

If unresolved state introduces its own constant source while cursor/mark glyphs remain local to the renderer, the codebase becomes less consistent rather than more consistent.

### Mitigation

- use this feature to move toward one shared UI glyph/theme registry
- avoid adding a second one-off unresolved-only constant mechanism

## Risk 8 — unresolved enrichment blocks changelist listing

If workspace-wide unresolved enrichment is slow or fails, the whole pending changelist view could become less reliable than it is today.

### Mitigation

- degrade unresolved enrichment failures to zero unresolved counts
- keep the base changelist list load successful even when unresolved enrichment is unavailable
- preserve command logging so the failure is still diagnosable

## Risk 9 — change 0 records leak into UI assumptions

If `p4 fstat -Ro -Ru` returns unresolved files in the Perforce `default` changelist, changelist-level counts can include records for entries the UI does not actually render.

### Mitigation

- explicitly ignore `change: 0` while the pending UI has no `default` changelist row
- document this as a current-scope decision

---

## Lessons applied from existing codebase patterns

This feature should explicitly apply lessons already visible in the project:

1. **Prefer dedicated pure helpers** for parsed counts.
   - The codebase already does this for opened and shelved counts.
2. **Enrich data before render**.
   - The renderer should stay dumb and predictable.
3. **Reuse existing predicate registries**.
   - The pending filter system already supports this extension naturally.
4. **Keep caches storing the final UI-ready shape**.
   - This avoids repeated annotation work and reduces state bugs.
5. **Use shared UTF-8 symbols intentionally**.
   - This project already values terminal-friendly UTF-8 layout.
6. **Prefer a single visual theme source**.
   - This prevents one feature from introducing a second glyph registry.
7. **Prefer stable object shapes at construction time**.
   - Reconstructing enriched file entries is safer than mutating them later.

---

## Future extensions

These are out of scope for the initial implementation, but the reviewed design should leave room for them.

### 1) Resolve workflow shortcut

Once unresolved state is rendered reliably, a future keybinding such as `R` could trigger a safe resolve workflow like `p4 resolve -as`, followed by a reload.

Why this fits the architecture:

- the glyph already identifies the actionable files and changelists
- the existing side-effect and workflow system can host the command cleanly
- reload semantics already exist and would naturally clear the glyph when the file becomes clean

### 2) Deeper inspector detail for unresolved files

Later, the inspector could optionally show *why* a file is unresolved by issuing a targeted preview-style command such as `p4 resolve -n` for the focused file only.

This should remain a later enhancement because it adds I/O and state transitions that are not needed for the first version.

### 3) ASCII fallback mode

If terminal compatibility becomes a concern, the shared UI theme can later support an ASCII mode where:

- `Glyphs.Unresolved = '!'`
- `Glyphs.Cursor` / `Glyphs.Mark` also receive ASCII-safe alternatives

This is another reason to centralize glyphs now instead of scattering literals.

---

## Acceptance criteria

The implementation is complete when all of the following are true:

- pending changelists with unresolved files show `⚠`
- pending changelists without unresolved files do not show `⚠`
- opened files that are unresolved show `⚠`
- opened files that are clean do not show `⚠`
- the file inspector states whether the selected file is unresolved
- pending view exposes a `Has unresolved files` filter
- selecting that filter restricts the changelist list correctly
- reload preserves correctness of unresolved counts and badges
- unresolved enrichment failure does not prevent pending changelists from loading
- analyzer passes
- tests pass

---

## Recommended implementation order summary

Recommended order:

1. shared constants
2. model fields
3. P4 unresolved helpers
4. changelist aggregation
5. pending filter
6. file enrichment
7. inspector refactor
8. changelist render badges
9. file render badges + inspector
10. tests + lint + regression

This order minimizes rework and keeps each step verifiable.
