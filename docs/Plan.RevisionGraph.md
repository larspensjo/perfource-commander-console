# PerFourceCommanderConsole — Revision Graph Plan

> Status: design phase — not yet implemented.

## Purpose

Display a vertical revision graph for a selected depot file, showing the file's
revision history and integration relationships to other depot paths. The graph
supports interactive navigation across integration lanes and on-demand expansion
of related file histories.

This plan is written against the current architecture (2026-03-24): reducer-driven
UDF, `Ui.ScreenStack` for screen hierarchy, async `ThreadJob` execution, and the
responsive-command patterns described in
[Plan.ResponsiveCommandExecution.md](Plan.ResponsiveCommandExecution.md).

---

## Goals

1. Show a vertical revision history for any depot file, oldest at top, newest at
   bottom.
2. Display integration records (both inbound and outbound) inline with each
   revision.
3. Allow the user to expand integrations into additional vertical lanes, loading
   the full history of the integrated file on demand.
4. Provide node-by-node keyboard navigation across the graph, including moving
   left/right to follow integrations between lanes.
5. Show detailed revision metadata (full description, user, date) for the
   currently focused node in a detail area at the bottom.
6. Support incremental loading: initial fetch is capped, with a "load more"
   action for additional history.

## Non-Goals (for initial implementation)

- Horizontal graph layout (p4v-style left-to-right).
- More than ~5 simultaneous lanes (cap and warn).
- Live streaming of `p4 filelog` output.
- Diff or preview from the graph view.
- Printing or exporting the graph.

---

## UX Overview

### Entry point

From the **Files screen**, pressing **`G`** on a file opens the Revision Graph
screen. This pushes `'RevisionGraph'` onto `Ui.ScreenStack`. Pressing **Escape**
pops back to the Files screen.

### Screen layout

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Lane headers (abbreviated depot paths with lane numbers)               │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  Scrollable graph area                                                   │
│  (vertical lanes with revision nodes and integration arrows)             │
│                                                                          │
│                                                                          │
├──────────────────────────────────────────────────────────────────────────┤
│  Detail area: full metadata for the currently focused node               │
│  (depot path, rev, changelist, action, user, date, description)          │
├──────────────────────────────────────────────────────────────────────────┤
│  Status bar                                                              │
└──────────────────────────────────────────────────────────────────────────┘
```

The graph area occupies most of the screen height. The detail area is a fixed
number of rows (e.g. 4–5 lines) at the bottom, above the status bar.

### Navigation

| Key           | Action                                                   |
|---------------|----------------------------------------------------------|
| `↑` / `↓`    | Move current node up/down in the flat row list           |
| `←`           | Follow inbound integration to source lane (left)         |
| `→`           | Follow outbound integration to target lane (right)       |
| `PageUp/Down` | Scroll by page                                           |
| `Home` / `End`| Jump to oldest / newest revision                         |
| `L`           | Load more history (older revisions)                      |
| `Escape`      | Return to Files screen                                   |

### Navigation semantics

- **Up/Down** moves through a flat list of navigable rows. Each revision node is
  a navigable row. Each integration record beneath a revision is also a navigable
  row. Non-navigable rows (vertical spine segments, blank lines) are skipped.

- **Right** on an integration record: if the integration target lane is not yet
  loaded, triggers an async `p4 filelog` for that depot path and creates a new
  lane. The cursor jumps to the corresponding revision node in the target lane.
  If the lane is already loaded, simply jumps to it.

- **Left** on an integration record: same behavior but toward the source lane.

- **Right/Left** on a plain revision node (no integration): no-op, or jump to
  the nearest adjacent lane at the same vertical position (TBD during
  implementation).

---

## Visual Design

### Single-lane view (initial state)

Oldest at top, newest at bottom. `►` marks the focused node.

```
 //depot/main/foo.cpp
 ════════════════════════════════════════════════════════════
 ● #1  add        cl#40000
 │
 ● #2  integrate  cl#41000
 │  ◄── //depot/dev/.../foo.cpp#3        [merge from]
 │  ──► //depot/release/.../foo.cpp#1    [branch into]
 │
 ● #3  integrate  cl#43500
 │  ◄── //depot/dev/.../foo.cpp#5        [copy from]
 │  ──► //depot/release/.../foo.cpp#2    [merge into]
 │
►● #4  edit       cl#45000
 ════════════════════════════════════════════════════════════
 #4  edit  cl#45000  2026-02-20  artist@WORKSTATION
 'Fixed animation blending weights for run cycle'
```

### Multi-lane view (after expanding integrations)

When the user navigates Right on an inbound integration, a new lane appears to
the left of the current lane (source of the integration). Outbound integrations
create lanes to the right.

```
 ① dev/.../foo.cpp       ② main/.../foo.cpp
 ══════════════════════════════════════════════════════════
 │                       ● #1  add       cl#40000
 │                       │
 ● #1  add    cl#39000   │
 │                       │
 ● #2  edit   cl#39500   │
 │                       │
►● #3  edit   cl#40500   │
 ├──────────────────────►● #2  integrate cl#41000
 │                       │  ──► //release/.../foo.cpp#1
 │                       │
 ● #4  edit   cl#42000   │
 │                       │
 ● #5  edit   cl#44000   │
 ├──────────────────────►● #3  integrate cl#43500
 │                       │  ──► //release/.../foo.cpp#2
 │                       │
 │                       ● #4  edit      cl#45000
 ══════════════════════════════════════════════════════════
 ① #3  edit  cl#40500  2026-01-18  dev@BUILD
 'Reworked particle system for water effects'
```

### Three-lane view with cross-lane integration

```
 ① dev/.../foo.cpp       ② main/.../foo.cpp     ③ release/.../foo.cpp
 ═══════════════════════════════════════════════════════════════════════
 │                       ● #1 add     40000      │
 │                       │                       │
 ● #1 add    39000       │                       │
 │                       │                       │
 ● #2 edit   39500       │                       │
 │                       │                       │
 ● #3 edit   40500       │                       │
 ├──────────────────────►● #2 integ  41000       │
 │                       ├──────────────────────►● #1 branch 41000
 │                       │                       │
 ● #4 edit   42000       │                       │
 │                       │                       │
 ● #5 edit   44000       │                       │
 ├──────────────────────►● #3 integ  43500       │
 │                       ├──────────────────────►● #2 merge  43500
 │                       │                       │
 │                       ● #4 edit   45000       │
 ═══════════════════════════════════════════════════════════════════════
```

### Cross-lane arrows (skipping intermediate lanes)

When an integration connects non-adjacent lanes (e.g. ① → ③ skipping ②), the
horizontal arrow crosses the intermediate lane's vertical spine:

```
 ● #6 edit   46000       │                       │
 ├───────────────────────┼──────────────────────►● #3 copy   46500
 │                       │                       │
```

The `┼` glyph indicates the arrow passes through lane ② without connecting to it.

### UTF-8 glyphs

| Purpose                    | Glyph | Unicode  |
|----------------------------|-------|----------|
| Revision node              | `●`   | U+25CF   |
| Revision node (focused)    | `◆`   | U+25C6   |
| Vertical spine             | `│`   | U+2502   |
| Tee right                  | `├`   | U+251C   |
| Branch down-right          | `╰`   | U+2570   |
| Branch down-left           | `╭`   | U+256D   |
| Horizontal line            | `─`   | U+2500   |
| Arrow right                | `►`   | U+25BA   |
| Arrow left                 | `◄`   | U+25C4   |
| Cross-through              | `┼`   | U+253C   |
| Integration inbound prefix | `◄──` | compound |
| Integration outbound prefix| `──►` | compound |
| Header separator           | `═`   | U+2550   |
| Vertical ellipsis (more)   | `⋮`   | U+22EE   |

---

## Data Model

### Perforce command

`p4 filelog -ztag -Mj` returns structured output per revision:

```
rev, change, action, type, time, user, client, desc
```

Plus zero or more integration records per revision:

```
how0, file0, srev0, erev0
how1, file1, srev1, erev1
...
```

The `how` field values include: `branch from`, `branch into`, `merge from`,
`merge into`, `copy from`, `copy into`, `delete from`, `delete into`,
`ignored`, `edit from`, `edit into`.

The `-m N` flag limits the number of revisions returned.

### Domain models

```text
RevisionNode
- DepotFile       : string    // full depot path
- Rev             : int       // revision number
- Change          : int       // changelist number
- Action          : string    // add, edit, integrate, delete, branch, ...
- FileType        : string    // text, binary, ...
- Time            : int       // Unix timestamp
- User            : string
- Client          : string
- Description     : string    // full description text
- Integrations    : IntegrationRecord[]

IntegrationRecord
- How             : string    // 'merge from', 'branch into', etc.
- Direction       : string    // 'inbound' | 'outbound' (derived from How)
- File            : string    // other depot path
- StartRev        : int       // start revision in other file
- EndRev          : int       // end revision in other file
```

Direction is derived from `How`:
- Contains `"from"` → `'inbound'` (something flowed into this file)
- Contains `"into"` → `'outbound'` (something flowed out of this file)

### Graph models

```text
GraphLane
- LaneIndex       : int       // 0-based, left-to-right
- DepotFile        : string   // full depot path
- Revisions        : RevisionNode[]
- IsLoading        : bool
- HasMore          : bool     // true if more history can be loaded
- Generation       : int      // async staleness guard

GraphRow
- RowType          : string   // 'Node' | 'Integration' | 'Arrow' | 'Spine'
- LaneIndex        : int      // which lane this row's primary content is in
- RevisionNode     : RevisionNode?       // for 'Node' rows
- IntegrationRecord: IntegrationRecord?  // for 'Integration' rows
- SourceLaneIndex  : int?     // for 'Arrow' rows
- TargetLaneIndex  : int?     // for 'Arrow' rows
- IsNavigable      : bool     // cursor can stop here
- SortKey          : int      // changelist number for vertical ordering
```

### State shape

Following the existing decomposition into `Data`, `Ui`, `Query`, `Derived`,
`Cursor`, and `Runtime`:

```text
State.Data.RevisionGraph
  .Lanes            : GraphLane[]         // ordered left-to-right
  .PrimaryLaneIndex : int                 // the lane opened originally
  .InitialDepotFile : string              // the file that was opened

State.Derived.GraphRows
                    : GraphRow[]          // flat list built from all lanes,
                                          // sorted by changelist number,
                                          // with integration and arrow rows
                                          // interleaved

State.Cursor.GraphRowIndex    : int       // index into GraphRows
State.Cursor.GraphScrollTop   : int       // scroll offset

State.Ui.ScreenStack          : includes 'RevisionGraph'
```

### Flat row generation algorithm

The derived `GraphRows` array is rebuilt whenever lane data changes. The
algorithm:

1. **Collect** all `RevisionNode` objects from all lanes.
2. **Sort** by `Change` (changelist number) ascending (oldest first, at top).
3. **Expand** each node into rows:
   a. Emit a `Node` row (navigable).
   b. For each integration record on this node:
      - Emit an `Integration` row (navigable) showing the integration summary.
      - If both source and target lanes are loaded, emit an `Arrow` row
        (non-navigable) on the connecting row between lanes.
4. **Fill gaps**: between nodes, emit `Spine` rows (non-navigable) to draw
   the vertical `│` connectors for each active lane.

For vertical ordering when multiple lanes have revisions at the same changelist,
use a secondary sort by lane index (leftmost first).

### Lane allocation

When the user expands an integration:

1. Determine if the target depot path already has a lane. If so, just navigate.
2. Determine placement:
   - **Inbound** integration (`merge from`, `copy from`, etc.): new lane goes
     **left** of the current lane.
   - **Outbound** integration (`branch into`, `merge into`, etc.): new lane goes
     **right** of the current lane.
3. Insert lane at the computed position, shifting existing lane indices.
4. Trigger async `p4 filelog` for the new lane.
5. Rebuild `GraphRows` once the data arrives.

Lane count is soft-capped at 5. Beyond that, a warning is shown in the status
bar and further expansion is blocked until a lane is collapsed (future feature).

### Lane width and horizontal fitting

Each lane needs enough columns to display:
- Node glyph (1 char) + space + `#N` (variable) + space + action (variable) +
  space + `cl#N` (variable)

A practical minimum lane width is ~22 characters. With inter-lane arrow space
(~4 chars), three lanes fit in ~80 columns, five lanes in ~120 columns.

When lanes don't fit the terminal width:
- Truncate the action or omit it (show in detail area instead).
- Abbreviate changelist as just the number.
- If still too tight, show only the focused lane and its immediate neighbors,
  with `◄` / `►` indicators for off-screen lanes (horizontal scrolling).

---

## Reducer Actions

### New actions

| Action                     | Payload                              | Effect                                     |
|----------------------------|--------------------------------------|--------------------------------------------|
| `OpenRevisionGraph`        | `{ DepotFile }`                      | Push screen, init state, trigger async load |
| `RevisionLogLoaded`        | `{ DepotFile, Revisions, HasMore }`  | Populate lane, rebuild GraphRows            |
| `RevisionLogFailed`        | `{ DepotFile, Error }`               | Show error in status bar                    |
| `ExpandIntegration`        | `{ DepotFile, Direction }`           | Create new lane, trigger async load         |
| `GraphNavigate`            | `{ Direction }` (Up/Down/Left/Right) | Move cursor through GraphRows / across lanes|
| `GraphLoadMore`            | `{ LaneIndex }`                      | Load older revisions for a lane             |
| `GraphPageUp` / `GraphPageDown` | (none)                          | Page-scroll the graph                       |
| `GraphHome` / `GraphEnd`   | (none)                               | Jump to oldest / newest                     |

### Reducer routing

Add a `'RevisionGraph'` case to the screen-stack dispatch in
`Invoke-BrowserReducer`. This routes to a new `Invoke-GraphReducer` function
(or a section within the existing reducer) that handles all `Graph*` actions.

Async completion actions (`RevisionLogLoaded`, `RevisionLogFailed`) are handled
at the top level (like `PendingChangesLoaded`) regardless of the active screen,
since data may arrive after the user has navigated away.

---

## Async Loading

### Initial load

When `OpenRevisionGraph` fires:

1. Set `State.Data.RevisionGraph` with one lane (`LaneIndex = 0`,
   `IsLoading = $true`).
2. Push `'RevisionGraph'` onto `ScreenStack`.
3. Set `PendingRequest` to trigger an async job:
   `p4 filelog -ztag -Mj -m $InitialRevisionLimit <depotFile>`
4. The loading state renders a "Loading..." indicator in the graph area.

When the job completes, dispatch `RevisionLogLoaded` with the parsed revisions.
The reducer populates the lane data, sets `IsLoading = $false`, and triggers
`Update-BrowserDerivedState` to build `GraphRows`.

### Expansion load

When `ExpandIntegration` fires:

1. Create a new lane with `IsLoading = $true`.
2. Set `PendingRequest` for the async job.
3. On completion, dispatch `RevisionLogLoaded` for the new lane.

### Generation guard

Each lane carries a `Generation` counter, incremented on reload. Async
completions include the generation; stale results are silently discarded. This
follows the same pattern as `FilesGeneration` / `PendingGeneration`.

### Load more

Pressing `L` triggers `GraphLoadMore` for the focused lane:

1. Record the current oldest revision's changelist as the upper bound.
2. Fire `p4 filelog -ztag -Mj -m $RevisionPageSize <depotFile>#1,<oldestRev-1>`
3. On completion, prepend the new revisions to the lane (they're older, so they
   go at the top).

### Initial revision limit

Use a constant (e.g. `$script:InitialRevisionLimit = 30`) for the first load,
and `$script:RevisionPageSize = 30` for subsequent "load more" fetches.

---

## Rendering

### Graph renderer

A new function `Build-GraphFrame` (or similar) produces the frame rows for the
graph screen. It:

1. Renders the **lane headers** at the top (abbreviated depot paths).
2. Renders the visible window of **GraphRows** based on scroll position:
   - For each visible row, render each lane's column:
     - `Node` row in its lane: `● #N  action  cl#N`
     - `Integration` row: indented `◄── path#N [how]` or `──► path#N [how]`
     - `Arrow` row: horizontal `├────────►` (or `◄────────┤`) connecting lanes,
       with `┼` crossing uninvolved lanes, and `│` for uninvolved spines
     - `Spine` row: `│` for each active lane
   - The focused node gets `◆` instead of `●` and a highlight color.
3. Renders the **detail area** at the bottom with the focused node's full
   metadata.
4. Renders the **status bar** with lane count, total revisions, and hints.

### Scroll thumb

Reuse `Get-ScrollThumb` from the existing render infrastructure.

### Frame diffing

Reuse the existing `FrameRow` / `Signature` / `Get-FrameDiff` / `Flush-FrameDiff`
pipeline. The graph renderer produces `FrameRow` objects just like the other
screens.

### Rendering in loading state

While a lane is loading, show a spinner or `⋯ loading` indicator in the lane
header and render the lane column as empty `│` spines.

---

## Implementation Phases

### Phase 1: Data layer and single-lane graph

**Scope:** `p4 filelog` command, parsing, single-lane rendering, basic navigation.

1. Add `Get-P4FileLog` to `P4Cli.psm1`:
   - Invokes `p4 filelog -ztag -Mj -m $limit <depotFile>`
   - Parses output into `RevisionNode` objects with `IntegrationRecord` arrays.
   - Handles `-m` limit and revision range syntax for "load more".

2. Add model factories to `Models.psm1`:
   - `New-RevisionNode`
   - `New-IntegrationRecord`
   - Helper: `Get-IntegrationDirection` (parses `how` into inbound/outbound).

3. Add state initialization:
   - `New-RevisionGraphState` factory.
   - Wire into `New-BrowserState` and `Copy-BrowserState`.

4. Add `Invoke-GraphReducer` (either in `Reducer.psm1` or a new
   `tui/GraphReducer.psm1`):
   - Handle `OpenRevisionGraph`, `RevisionLogLoaded`, `RevisionLogFailed`.
   - Handle `GraphNavigate` (Up/Down only), `GraphPageUp/Down`, `GraphHome/End`.
   - Implement flat-row generation in `Update-GraphDerivedState`.

5. Add graph rendering:
   - `Build-GraphFrame` in `Render.psm1` (or a new `tui/GraphRender.psm1`).
   - Single-lane layout: node rows, integration rows, spine rows.
   - Detail area at bottom.
   - Status bar.

6. Wire entry point:
   - Map `G` key in Files screen to `OpenRevisionGraph` action.
   - Route `'RevisionGraph'` screen in reducer and render dispatchers.

7. Add tests:
   - `tests/RevisionGraph.Tests.ps1`
   - Test `p4 filelog` output parsing.
   - Test flat-row generation from lane data.
   - Test reducer transitions (navigate, load completion).
   - Test rendering output for known graph states.

### Phase 2: Multi-lane expansion

**Scope:** Lane creation, cross-lane arrows, Left/Right navigation.

1. Implement `ExpandIntegration` action:
   - Lane allocation (inbound → left, outbound → right).
   - Async load for new lane.
   - Rebuild `GraphRows` with multi-lane vertical sorting.

2. Implement Left/Right navigation:
   - Follow integration links between lanes.
   - Auto-expand if target lane not yet loaded.
   - Cursor jumps to the corresponding node in the target lane.

3. Multi-lane rendering:
   - Lane headers with numbered labels.
   - Horizontal arrow rows connecting lanes.
   - Cross-lane `┼` glyph for arrows that skip intermediate lanes.
   - Lane width calculations and truncation rules.

4. Add tests for multi-lane scenarios.

### Phase 3: Load more and polish

**Scope:** Incremental history loading, edge cases, UX polish.

1. Implement `GraphLoadMore`:
   - Fetch older revisions with revision range syntax.
   - Prepend to lane data, rebuild rows.
   - `⋮ load more` visual at the top of each lane that has more history.

2. Vertical gap compression:
   - Collapse long runs of empty `│` spine rows between nodes into a single
     `⋮` row to save vertical space.

3. Horizontal overflow:
   - When lanes exceed terminal width, implement focused-lane windowing.
   - Show `◄` / `►` indicators for off-screen lanes.

4. Edge cases:
   - Deleted files (action = `delete`): show as normal nodes with a visual
     indicator.
   - Renamed files: `p4 filelog` with `-i` follows renames; without `-i` it
     stops. Since we load per-path, renames appear as integrations to follow.
   - Very long descriptions: truncate in detail area with scroll or wrap.

5. Polish:
   - Theme colors for different integration types.
   - Keyboard hints in status bar.
   - Performance: cache `GraphRows` and only rebuild when lane data changes.

---

## File Organization

| File                              | Contents                                    |
|-----------------------------------|---------------------------------------------|
| `p4/P4Cli.psm1`                  | `Get-P4FileLog` (new function)              |
| `p4/Models.psm1`                 | `New-RevisionNode`, `New-IntegrationRecord` |
| `tui/Reducer.psm1`               | Screen routing for `'RevisionGraph'`        |
| `tui/GraphReducer.psm1` (new)    | `Invoke-GraphReducer`, graph state helpers  |
| `tui/GraphRender.psm1` (new)     | `Build-GraphFrame`, graph row rendering     |
| `tui/Helpers.psm1`               | Shared helpers if needed                    |
| `tests/RevisionGraph.Tests.ps1` (new) | All graph-related tests                |

### Module integration

New `.psm1` files must be added to `PerfourceCommanderConsole.psd1`
(`NestedModules`) and imported appropriately. The main module
(`PerfourceCommanderConsole.psm1`) must wire the new screen into the event loop,
reducer dispatch, and render dispatch.

---

## Risks and Mitigations

| Risk                               | Mitigation                                |
|------------------------------------|-------------------------------------------|
| `p4 filelog` slow on large files   | `-m` limit + async loading + generation guard |
| Terminal too narrow for multi-lane | Focused-lane windowing + truncation rules |
| Deep integration chains            | Lane cap (5) + manual expansion only      |
| Stale async completions            | Generation counter per lane               |
| Complex cross-lane arrow rendering | Phase 2 scope; single-lane works standalone |
| UTF-8 glyph rendering varies      | Test on Windows Terminal; provide fallback ASCII if needed |
