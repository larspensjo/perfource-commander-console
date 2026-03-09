# PerFourceCommanderConsole — Workflow, Selection, Confirmation, and Menu System Plan

## Purpose

This document proposes a scalable architecture for **multi-changelist workflows** in the TUI.

Primary goals:
- Let the user **mark multiple changelists**.
- Support bulk workflows such as:
  - delete marked changelists
  - move opened files from marked changelists to the currently focused target changelist
- Add a **simple confirmation dialog** for destructive or multi-step actions.
- Add a **menu system** suitable for a growing number of workflows.
- Keep the design **elegant, robust, flexible, and testable**.
- Prefer **Correctness by Construction** over ad hoc patches.

This plan is intended for **external review** before implementation.

---

## Confirmed product decisions

These decisions are already settled for this plan:

1. There is **one global changelist selection**.
   - It is not per-view.
   - It persists across filters, quick search, and switching between Pending / Submitted / other views.
   - Hidden items remain selected.
2. Successful destructive workflows must **remove deleted changelists from the selection**.
3. The bottom status bar should show the **current selection count**.
4. Menus should support **Alt+F** and **Alt+V** as the primary activation path.
5. Confirmation should start as a **simple Yes/No dialog**.
6. For bulk move workflows, the default destination is the **currently focused changelist**.
7. Menus should be **context sensitive by enablement**, not by structure.
   - Menus stay stable.
   - Inapplicable actions are shown as disabled.
8. The UI should use **UTF-8 special characters** wherever they improve clarity and aesthetics.

---

## Design principles

The implementation should follow these principles consistently:

- **Unidirectional Data Flow**
- **Strict reducer purity**: the reducer performs state transitions only; it never executes p4 commands directly
- **Single source of truth** for state
- **One request-dispatch mechanism** for side effects; avoid parallel flag systems
- **Typed intent actions** rather than directly triggering side effects from input handlers
- **Exhaustive dispatchers** that fail loudly on unsupported cases
- **Stable menus** with dynamic enable/disable predicates
- **Declarative workflow registration** instead of scattered switch statements
- **Shared overlay system** for help, confirmation, menus, and command progress
- **Behavioral tests first** for reducer, render, integration, and p4 wrapper layers

This is the best way to stop the current pattern where a feature works in one path but is forgotten in another.

---

## UX overview

### Core interaction model

The user can:
- move the cursor through changelists
- mark or unmark individual changelists
- mark all currently visible changelists
- clear all marks
- invoke actions from menus or shortcuts
- confirm or cancel workflows in a dialog

### Visual model

Each changelist row can have two independent visual states:

1. **Focused**
   - current cursor row
   - existing highlight behavior continues
2. **Marked**
   - selected for later workflow execution
   - remains visible even when not focused

This distinction is important. Focus is temporary navigation state; mark state is durable workflow state.

### Example workflow

1. User marks several changelists.
2. User opens **File** menu with **Alt+F**.
3. User chooses **Delete marked changelists**.
4. A confirmation dialog appears with:
   - title
   - selection count
   - affected changelist IDs or a summarized preview
   - confirm / cancel prompt
5. On confirm, workflow executes.
6. Successful items are removed from UI and from the marked set.
7. Result is visible in command log and status bar.

---

## Selection model

## One global selection set

Add a single mark set to state:

- `MarkedChangeIds : HashSet[string]`

Recommended placement:
- store `MarkedChangeIds` under **`Query`**

Rationale:
- it is user intent state, similar in nature to `SelectedFilters`
- it is not derived data
- it is not ephemeral runtime state
- it should survive filter and view changes without being recomputed

Why `HashSet[string]`:
- fast membership tests
- order does not matter
- existing state copy logic already supports `HashSet[string]`
- string change IDs are already the stable UI identity
- the current `Copy-StateObject` behavior already makes this a low-risk addition

### Behavior rules

- Marks persist across:
  - filters
  - quick search
  - view changes
  - screen changes
- Marks are removed when:
  - the user explicitly unmarks
  - the user clears selection
  - a workflow succeeds and the changelist no longer exists in the relevant list
- Marks should be reconciled on refresh so changelists deleted outside the TUI do not remain indefinitely in `MarkedChangeIds`
- Marks should not be silently dropped because an item becomes temporarily invisible.

### Mark all visible

This must be first-class and easy to use.

Recommended commands:
- **Mark current**
- **Unmark current**
- **Toggle mark current**
- **Mark all visible**
- **Clear all marks**

Recommended behavior for **Mark all visible**:
- union the visible changelist IDs into `MarkedChangeIds`
- do not clear previously marked hidden items
- show the new selection count immediately in the status bar

Optional future extension:
- **Unmark all visible**
- **Invert visible selection**

---

## Menu system

## Main goal

The number of workflows is growing. The current flat shortcut model will become hard to remember and hard to evolve.

A menu layer should become the **organizational shell** for workflows.

## Menus to introduce

### File menu

Examples:
- Delete marked changelists
- Move opened files from marked changelists to focused target
- Clear selection
- Mark all visible
- Refresh
- Quit

### View menu

Examples:
- Pending view
- Submitted view
- Command log view
- Toggle hide unavailable filters
- Expand / collapse details
- Help

## Context sensitive menus

The **menu structure must remain stable**.

Do **not** hide menu items dynamically based on context.
Instead:
- keep the same menu layout
- compute whether each action is enabled
- render disabled items visually
- reject execution reducer-side as well if somehow invoked anyway

This gives:
- predictable muscle memory
- easier documentation
- simpler testing
- fewer surprising UI changes

### Example enable rules

- `Delete marked changelists`
  - enabled only if there is at least one marked changelist
  - may be further restricted to pending changelists only
- `Move opened files from marked to focused`
  - enabled only if:
    - there are marked changelists
    - a valid focused target exists
    - focused target is of the correct type
- `Mark all visible`
  - enabled only if there is at least one visible changelist
- `Submitted view`
  - disabled only if already in submitted view? optional
  - or left enabled but no-op; better to disable visually if already active

## Activation

Primary path:
- **Alt+F** → File menu
- **Alt+V** → View menu

Recommended fallback path:
- one terminal-safe fallback, such as **F10**, if Alt chord support is inconsistent across consoles

## Navigation inside menus

Suggested MVP:
- Alt+F / Alt+V opens menu
- accelerator key selects action immediately if unique
- Up/Down navigates items
- Enter executes enabled item
- Esc closes menu
- Left/Right switches top-level menu while menu is open

---

## Confirmation dialog

## Scope

Introduce a simple reusable confirmation dialog for workflows.

Use it for:
- delete marked changelists
- bulk move operations
- future bulk operations with side effects

## Dialog content

A confirmation dialog should be structured, not ad hoc text.

Fields:
- `Title`
- `SummaryLines`
- `ConsequenceLines`
- `ConfirmLabel`
- `CancelLabel`
- `WorkflowPayload`

### Example

Title:
- `Delete marked changelists?`

Summary lines:
- `Selected: 4 changelists`
- `Pending: 4`
- `Will attempt deletion in sequence`

Consequence lines:
- `Only empty changelists can be deleted`
- `Successful deletions will be removed from selection`

Footer:
- `Y = confirm   N / Esc = cancel`

## Interaction model

MVP confirmation keys:
- `Y` or Enter = confirm
- `N` or Esc = cancel

The reducer should open the dialog from a structured request. The main loop should only execute the workflow after explicit confirmation.

Where feasible, the dialog should also support **lightweight previews** before the operation starts.
Examples:
- for delete: how many changelists will be attempted
- for move: how many changelists and, if cheaply available, how many opened files in total will be moved

---

## Overlay architecture

The current UI already has help overlay and command modal behavior. That should evolve into a **single overlay framework**.

The overlay system should be modeled as a **mutually exclusive state**, not as multiple independent booleans.

Recommended shape:
- `OverlayMode = 'None' | 'Help' | 'Menu' | 'Confirm' | 'CommandProgress'`
- `OverlayPayload = <typed payload for the active mode>`

Recommended overlay types:
- `Help`
- `Menu`
- `Confirm`
- `CommandProgress`

## Why this matters

Without a unified overlay model, the number of booleans and precedence bugs will grow quickly.

A single overlay system gives:
- one rendering path
- one precedence model
- one escape/close behavior model
- simpler tests
- no invalid combinations such as help + confirm + menu competing for input simultaneously

## Recommended precedence

Highest priority first:
1. command progress / busy state
2. confirmation dialog
3. menu
4. help

That order prevents accidental confirmation or menu interaction during active work.

## Routing rule

Input routing should become explicitly overlay-first:

1. if `OverlayMode -ne 'None'`, route to an overlay-specific reducer
2. otherwise route by `ScreenStack[-1]`

This prevents screen-specific reducers from consuming keys that belong to a menu or confirmation dialog.

### Escape behavior

When an overlay is active, `Esc` should close or cancel the overlay **before** any screen-pop logic runs.
Examples:
- confirm open over Files screen → `Esc` cancels confirm, does not close Files screen
- menu open over Changelists → `Esc` closes menu only
- progress overlay with `Dismissable = $false` → `Esc` does nothing

---

## Workflow architecture

## Core idea

Treat each user operation as a **workflow** with:
- metadata
- enable predicate
- confirmation builder
- executor
- success/failure summary

Critically, workflows must preserve strict UDF separation:
- the **Reducer** computes state transitions only
- the **Main Loop / Effect Handler** executes p4 side effects
- side effects report results back by dispatching new actions into the reducer

This is the most scalable structure for the future.

## Workflow registry

Recommended declarative model:

Each workflow entry should define:
- `Id`
- `Menu`
- `Label`
- `Accelerator`
- `IsEnabled(State)`
- `BuildRequest(State)`
- `BuildConfirmation(Request, State)`
- `Execute(Request, State)`
- `ApplySuccess(Result, State)`

This keeps menus, reducers, and executors aligned.

The registry itself should be validated at module load time.
Examples of required checks:
- every workflow has a non-empty `Id`
- `Id` values are unique
- required scriptblocks exist (`IsEnabled`, `BuildRequest`, and any required confirmation/execution fields)
- declared menu names are valid

This is a strong Correctness-by-Construction step: invalid registrations should fail early at startup, not later during interaction.

Recommended effect flow:
1. user input dispatches an intent action
2. reducer validates state and emits a structured `PendingWorkflow`
3. UI opens confirmation if required
4. on confirm, the effect handler executes the workflow outside the reducer
5. effect handler dispatches result actions such as:
   - `WorkflowProgressUpdate`
   - `WorkflowChunkComplete`
   - `WorkflowFinished`
   - `WorkflowFailed`

## Why a registry is preferable

Without a registry, growth leads to:
- more input special cases
- larger reducer switches
- more one-off runtime flags
- harder-to-test coupling between UI and side effects

With a registry:
- menus are data-driven
- action enablement is centralized
- confirmation text is consistent
- workflows can be tested in isolation

---

## Runtime request model

The current runtime side-effect model already handles things like reloads and file loading. That should be generalized carefully.

Recommended next abstraction:
- one structured runtime request, e.g. `PendingRequest`

Important migration rule:
- do **not** add `PendingWorkflow` alongside the existing cluster of runtime flags as a second execution path
- instead, migrate the existing flags into the same request-dispatch model so the application keeps **one** side-effect mechanism

Current examples that should eventually become request kinds rather than bespoke flags:
- reload pending
- reload submitted
- load more submitted
- load files
- fetch describe
- delete change
- run workflow

Example shape:
- `Kind`
- `ChangeIds`
- `TargetChangeId`
- `Arguments`
- `Confirmation`

Recommended companion result actions:
- `WorkflowProgressUpdate`
- `WorkflowChunkComplete`
- `WorkflowFinished`
- `WorkflowFailed`

## Benefits

- fewer scattered runtime booleans
- easier debugging
- easier command logging and error reporting
- easier future batching and retry logic
- no split-brain between old ad hoc effect flags and new workflow requests

## Fail-fast rule

Unknown workflow kinds or unsupported workflow payloads must **throw immediately**.
Never silently no-op.

This follows the same robustness direction already established in the codebase.

For implementation, prefer a discriminated-union style request object:
- one request slot
- one dispatcher
- exhaustive `Kind` matching
- throw on unknown kinds

---

## p4 integration architecture

## Bulk delete

Wrap bulk delete orchestration behind a dedicated workflow executor.

Responsibilities:
- iterate marked changelists
- call existing delete wrapper
- collect per-change result
- update lists and selection on success
- preserve failed items in selection for user visibility

Recommended behavior:
- continue through the full batch rather than stopping on first failure
- remove only **successful** IDs from `MarkedChangeIds`
- keep failed IDs selected so the user can immediately retry or inspect them
- emit progress updates for long batches

## Move opened files from marked changelists to focused target

This should also be wrapped behind dedicated helpers in the p4 layer.

Design goals:
- no raw p4 command assembly in menu/reducer logic
- structured result per source changelist
- good command log visibility
- partial failure reporting

### Important semantic questions for implementation

These should be reviewed explicitly before coding:
- If the focused target is also marked, is that allowed?
- Should empty marked changelists be skipped silently or reported?
- Should the workflow stop on first failure or continue through all marked changelists?
- Should submitted changelists be excluded automatically?

Recommended default:
- continue through all marked pending changelists
- skip impossible cases with explicit result reporting
- preserve failed items in selection

If the workflow is large enough to be noticeable, show a `CommandProgress` overlay with an explicit counter such as `Processed 4/10…` and, optionally, a UTF-8 progress bar.

---

## Rendering plan

## Mark visualization

Use UTF-8 symbols to improve clarity.

Recommended glyph system:
- focused row marker: `▶`
- marked row badge: `●` or `✓`
- combined focused+marked state: show both, e.g. `▶●`

Alternative glyphs worth testing:
- `◆`
- `■`
- `★`

## Disabled menu items

Render disabled items visibly dimmed, not removed.

Suggested visual treatment:
- gray text
- muted accelerator hint
- optional disabled prefix like `·` or `⨯`

## Confirmation dialog

Use box-drawing and typography consistently:
- rounded borders
- centered title
- warning icon where appropriate, e.g. `⚠`
- success icon `✓`
- failure icon `✗`

For long-running batch operations, consider UTF-8 block elements for progress, such as:
- `░`, `▒`, `▓`, `█`
- example: `[██████░░░░] 60%`

## Selection count in status bar

Suggested status bar fragments:
- `● Selected: 3`
- `◌ Selected: 0`

## UTF-8 enhancements

Use UTF-8 special characters wherever reasonable, but keep them purposeful.

Recommended areas:
- selection badges
- warning/confirm icons
- disabled-state indicators
- menu accelerators and separators
- result summaries
- workflow category icons if subtle and consistent

Examples:
- `⚠` warning
- `✓` success
- `✗` failure
- `→` destination
- `●` marked
- `…` truncation
- `│`, `╭`, `╮`, `╰`, `╯` borders

Principle:
- improve scanability and aesthetics
- do not overload the UI with decorative noise

---

## Input model

## Current problem

The current input system is single-key oriented. A menu system and workflow shell will need more structure.

## Recommendation

Represent input as higher-level actions early.

Examples:
- `OpenMenu(File)`
- `OpenMenu(View)`
- `ToggleMarkCurrent`
- `MarkAllVisible`
- `ClearMarks`
- `AcceptDialog`
- `CancelDialog`
- `ChooseMenuItem(DeleteMarked)`

This keeps the reducer independent of raw console key details.

## Modifier-aware input

`Alt+F` and `Alt+V` require explicit modifier handling.

Recommendation:
- inspect `KeyInfo.Modifiers` in the input mapper
- map modifier chords before the ordinary single-key switch

Examples:
- `Alt+F` → `OpenMenu(File)`
- `Alt+V` → `OpenMenu(View)`

## Menu input mode

Menus introduce a modal input context. While a menu is open, arrow keys should navigate menu items rather than changelists.

Preferred strategy:
- make the input mapper overlay-aware
- when `OverlayMode = 'Menu'`, emit menu-specific actions such as:
   - `MenuMoveUp`
   - `MenuMoveDown`
   - `MenuSelect`
   - `MenuClose`
   - `MenuSwitchLeft`
   - `MenuSwitchRight`

This is more explicit and testable than overloading generic `MoveDown` / `MoveUp` actions.

## Suggested MVP shortcuts

- `Insert` or `M` = toggle mark current
- `Shift+M` or dedicated menu command = mark all visible
- `Alt+F` = open File menu
- `Alt+V` = open View menu
- `Esc` = close menu or dialog

If modifier support proves unreliable in terminals, preserve a fallback path through F10 or direct menu-opening actions.

---

## State model sketch

Recommended additions:

### Query
- `MarkedChangeIds : HashSet[string]`

### Ui
- `ActiveMenu : string?`
- `MenuState : object?`
- `OverlayMode : string`
- `OverlayPayload : object?`

### Runtime
- `PendingWorkflow : object?`

### Derived
- optionally `VisibleMarkedCount`
- optionally precomputed enabled menu entries for rendering speed

## Invariants

- A marked changelist is identified only by its stable change ID.
- Filtering/search must never mutate the mark set.
- `SwitchView` must not clear `MarkedChangeIds`.
- Workflow execution must never rely on visible rows only; it must use IDs.
- Disabled menu entries must be non-executable even if a key path reaches them.
- Overlay state must be exclusive and precedence-driven.
- On refresh, stale marked IDs that no longer exist in the loaded data should be garbage-collected.
- Unknown reducer actions, request kinds, and workflow kinds should fail fast rather than silently falling through.

---

## Correctness by Construction opportunities

These changes would strongly reduce future regressions:

1. **Central workflow registry**
   - prevents action definitions from drifting across input, menus, and execution
2. **Single overlay renderer**
   - prevents help/menu/dialog conflicts
3. **Single menu definition source**
   - prevents mismatches between visible items and executable items
4. **Exhaustive workflow dispatcher**
   - unsupported kinds throw immediately
5. **Stable selection by ID**
   - robust under sorting, filtering, and screen changes
6. **Validation in two layers**
   - menu enable predicate
   - reducer / executor hard validation

This is the strongest path to robustness for a system expected to grow considerably.

---

## Testing strategy

## Reducer tests

Add tests for:
- toggle mark current
- mark persists across filter/search/view changes
- mark all visible unions visible IDs into selection
- clear selection empties mark set
- successful delete removes IDs from selection
- refresh reconciles stale marked IDs that were deleted outside the TUI
- `SwitchView` does not clear `MarkedChangeIds`
- menu open/close
- disabled actions remain non-executable
- confirmation accept/cancel
- invalid workflow requests throw
- overlay precedence and reentrancy (e.g. menu open request while confirm is active)
- overlay-first `Esc` behavior (cancel overlay before screen close)

## Render tests

Add tests for:
- marked row glyphs
- focused + marked rendering combination
- selection count in status bar
- menu rendering with disabled entries
- confirmation dialog summary rendering
- command-progress overlay rendering
- UTF-8 indicator presence where expected

## Input tests

Add tests for:
- Alt+F / Alt+V
- mark toggle key
- mark all visible key or menu action
- dialog accept/cancel keys
- fallback menu activation path
- menu-mode key remapping while a menu overlay is open

## Integration tests

Use the existing mocked console + mocked p4 approach to test flows like:
- mark three changelists
- open File menu
- choose delete marked
- confirm
- verify expected p4 calls and resulting state

Also test:
- mark all visible then delete
- mark pending items, switch view, switch back, selection preserved
- move opened files from marked to focused target
- partial failure in a multi-item batch leaves failed IDs selected and removes only successful IDs
- overlay input precedence over Files / Changelists screen navigation

## p4 wrapper tests

Add focused tests for any new wrappers supporting move/reopen style workflows.

Also add effect-dispatcher tests ensuring unsupported workflow kinds throw immediately rather than silently no-op.

---

## Implementation sequence

Recommended order:

### Phase 0 — Effect dispatch cleanup
- consolidate current runtime effect flags into a single request-dispatch model
- ensure the main loop has one side-effect execution path before workflow-specific requests are added

### Phase 1 — Foundation
- add `MarkedChangeIds`
- add reducer actions for mark/unmark/mark all visible/clear
- render marked state and selection count

### Phase 2 — Overlay framework
- unify help/menu/confirm/progress overlay model
- implement simple Yes/No confirmation dialog

### Phase 3 — Menu shell
- add File and View menu definitions
- add context-sensitive disabled rendering
- add Alt+F / Alt+V plus fallback activation path

### Phase 4 — Workflow execution framework
- add structured `PendingRequest`
- add validation and exhaustive execution dispatcher
- add progress update actions for long-running workflows

### Phase 5 — First workflows
- delete marked changelists
- move opened files from marked changelists to focused target

### Phase 6 — Hardening
- improve result summaries
- refine menu keyboard navigation
- add richer review/preview dialogs if needed

This order minimizes rework and keeps each step reviewable.

---

## Risks and mitigations

### Risk: menu logic spreads across input, reducer, render, and executor
Mitigation:
- use a declarative menu/workflow registry

### Risk: selection accidentally tied to visible rows
Mitigation:
- selection stores IDs only
- visibility is derived state only

### Risk: terminal Alt behavior is inconsistent
Mitigation:
- implement fallback activation path
- keep menu model independent of raw key details

### Risk: too many runtime flags accumulate
Mitigation:
- replace ad hoc flags with structured workflow requests

### Risk: old effect flags and new workflow requests coexist indefinitely
Mitigation:
- migrate all effect dispatch into one request model early
- avoid introducing a second side-effect path

### Risk: overlay keys leak into screen reducers
Mitigation:
- enforce overlay-first routing in the top-level reducer

### Risk: invalid workflow definitions are discovered late
Mitigation:
- validate workflow registry entries at module load time

### Risk: confirmation logic duplicates command modal behavior
Mitigation:
- unify overlays under one renderer and one precedence model

---

## Nice future extensions

Possible future additions once the shell exists:
- unmark all visible
- invert visible selection
- range marking
- only show marked / marked-only filter mode
- workflow previews before confirmation
- richer multi-step dialogs
- recent or favorite target changelists
- command palette sharing the same workflow registry
- workflow categories and search
- batch result viewer
- undo-like safety for reversible workflows
- undo clear selection / restore last selection set

---

## Review questions for external feedback

Reviewers should pay special attention to:

1. Is one global mark set the right long-term model?
2. Is a declarative workflow registry the right abstraction level now?
3. Should menus be popup overlays first, or should the layout reserve a top menu row from the start?
4. Is simple Yes/No sufficient for destructive workflows, or should some operations use typed confirmation later?
5. Is the focused changelist the right default target for bulk move workflows?
6. Are there terminal compatibility concerns around Alt+key that should change the MVP activation strategy?
7. Are there additional invariants we should encode early to prevent future workflow bugs?

---

## Recommendation summary

The recommended path is:
- implement **global durable marking by changelist ID**
- add **mark all visible** as a first-class action
- introduce a **unified overlay system**
- implement **stable File / View menus** with **disabled but visible** actions
- route all bulk actions through a **declarative workflow registry** and a **structured executor**
- use **UTF-8 symbols deliberately** to make state, warnings, and outcomes easy to scan

This is the best foundation for a system that is expected to grow considerably without becoming brittle.
