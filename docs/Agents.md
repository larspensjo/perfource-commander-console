# General instructions how to code this project

## Architecture

* Use the Unidirectional Data flow design pattern (UDF).
* Prioritize elegance, robustness and flexibility.
* Use the principle Correctness by Construction.
* Avoid repetition.
* Don't repeat yourself.
* Avoid "naked constants". Assign them to a variable, and use the variable instead. Make sure to share the same variable accross file.

## Workflows

* When a bug is found or fixed, analyze the lessons learned. If there is a robustness issue, investigate if there is a change that can prevent future problems of the same type to recur.

## PowerShell 7.0 Baseline

This project targets PowerShell 7.0 or newer. Use PowerShell 7 behavior as the reference when editing any `.ps1` / `.psm1` file.

* **Use `pwsh` for commands and automation.** Keep scripts, tasks, and docs aligned to PowerShell 7.
* **UTF-8 is the default text encoding.** Use UTF-8 for source files; a BOM is optional unless a specific integration requires it. Always actively consider how UTF-8 graphical characters (symbols, box-drawing characters, typography, icons, UI decorators) can be used to improve the layout, readability, and user experience of the terminal interface.
* **PowerShell 7 language/runtime features are allowed.** This includes APIs such as `[datetime]::UnixEpoch` and cmdlet options such as `Sort-Object -Stable`.

## PowerShell Coding Conventions

### `Write-Output -NoEnumerate` — never wrap the call in `@()`

Several functions in this codebase (e.g. `Merge-AdjacentSegments`, `Write-ColorSegments`) return an array **as a single value** using `Write-Output -NoEnumerate @($array)`. This is the deliberate convention for preserving array identity across the PowerShell pipeline.

**Footgun:** wrapping such a call in `@()` silently re-wraps the returned array as a 1-element array:

```powershell
# WRONG — produces @( @(seg1,seg2,...) ), Count=1
$segs = @(Merge-AdjacentSegments -Segments $input)

# CORRECT — produces @(seg1, seg2, ...) as intended
$segs = Merge-AdjacentSegments -Segments $input
```

This bug produces no error; the variable just holds a nested array instead of a flat one, causing downstream code to silently misbehave (e.g. rendering blank rows). Always assign the result directly.

Any function that uses `Write-Output -NoEnumerate` should carry a `# Returns array-as-value; do NOT wrap call in @()` comment on its closing line or in its help block.

### Normalize 0..N results at call boundaries

PowerShell silently turns an empty command result into `$null` unless the caller explicitly normalizes it as an array.

**Footgun:** a function that conceptually returns “zero or more items” can return `$null` at the call site, which then breaks downstream parameter binding for collection parameters.

```powershell
# WRONG — $files becomes $null when Get-P4OpenedFiles returns no items
$files = Get-P4OpenedFiles -Change $Change
Use-Something -FileEntries $files

# CORRECT — $files is always an array, including the empty case
$files = @(Get-P4OpenedFiles -Change $Change)
Use-Something -FileEntries $files
```

Rules:

* When consuming any function that semantically returns **0..N items**, normalize immediately with `@(...)` unless the function explicitly documents a different contract.
* When declaring a parameter that semantically accepts an empty collection, prefer `[AllowEmptyCollection()]` and consider `[AllowNull()]` if `$null` is a meaningful or likely boundary value.
* For cache/state writes, store normalized arrays rather than allowing `$null` and `object` shape drift.

Apply this especially at I/O boundaries (`Invoke-P4`, file-cache population, parser helpers, and workflow side effects), where empty results are common and should not be treated as exceptional.

### `Import-Module` inside a `.psm1` must use `-Global`

When a `.psm1` file imports another module without `-Global`, PowerShell makes the imported module a private *nested module* of the importer. This **removes** it from the global session, making its exported functions invisible to every other caller — including test code.

```powershell
# WRONG — Models becomes P4Cli's private nested module; callers can't see New-RevisionNode
Import-Module (Join-Path $PSScriptRoot 'Models.psm1') -Force

# CORRECT — Models stays in the global session, visible to all callers
Import-Module (Join-Path $PSScriptRoot 'Models.psm1') -Force -Global
```

Rule: every `Import-Module` statement inside a `.psm1` that imports a **shared** dependency must include `-Global`.

### `(if ...)` is invalid in argument position

PowerShell treats `if` as a command name when it appears as an argument to a function call. The parser will error with *"The term 'if' is not recognized…"*.

```powershell
# WRONG — PowerShell tries to invoke a command named 'if'
New-Thing -Action (if ($cond) { 'x' } else { 'y' })

# CORRECT — pre-compute to a variable
$action = if ($cond) { 'x' } else { 'y' }
New-Thing -Action $action
```

### Empty-array pipeline collapse from `if` expressions

An `if` / `else` expression that yields `@()` (empty array) returns `$null` through the PowerShell pipeline. Assigning such an expression to a variable and later calling `.Count` on it throws under `Set-StrictMode -Version Latest`.

```powershell
# WRONG — $rows is $null when the condition is false; $rows.Count throws
$rows = if ($cond) { @($source) } else { @() }

# CORRECT — initialize unconditionally, then conditionally populate
$rows = @()
if ($cond) { $rows = @($source) }
```

This is a specific instance of the general "Normalize 0..N results" rule, but the `if`-expression form is particularly subtle because it looks like it always produces an array.

### Pester 5 test file structure — use per-`Describe` `BeforeAll`

In Pester 5, a test file is executed in two phases:

* **Discovery** — top-level code runs to register `Describe`/`It` blocks.
* **Execution** — only code inside `BeforeAll`, `BeforeEach`, `AfterEach`, `AfterAll`, and `It` blocks runs.

Functions defined at the top level of a test file exist only during discovery and are **not visible** inside `It` or `BeforeEach` blocks.

```powershell
# WRONG — New-Helper is defined at top level; invisible during test execution
function New-Helper { ... }
Describe 'Foo' {
    It 'works' { New-Helper }   # CommandNotFoundException
}

# CORRECT — import inside BeforeAll with -Global so functions are visible everywhere
Describe 'Foo' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\MyModule.psm1') -Force -Global
    }
    It 'works' { New-Helper }   # works
}
```

Rules:

* Every `Describe` block that calls module functions must have its own `BeforeAll { Import-Module ... -Force -Global }`.
* Helper functions needed by `BeforeEach` / `It` blocks must also be defined inside `BeforeAll` using `function script:Name { ... }`.
* The top-level `Import-Module -Force -Global` (outside any `Describe`) is useful for IDE tooling but **cannot be relied on** for test execution.

---

## Validating Changes

### Linter

Run PSScriptAnalyzer via the VS Code task, or directly in the terminal:

```powershell
pwsh -NoProfile -File .vscode/Invoke-Linter.ps1
```

This analyses all `.ps1`, `.psm1`, and `.psd1` files in the workspace using the settings in `PSScriptAnalyzerSettings.psd1`. Output is formatted as `file(line,col): severity rulename: message`. Fix all reported warnings and errors before committing.

### Pester Tests

* Use unit tests to lock-in functionality.
* Use Dependency Injection to make testing easier.
* Test behavior and contracts, not arbitrary literals. Prefer assertions about outcomes, transitions, emitted effects, and command arguments over direct checks of internal/config constants.

**Important:** Always run Pester tests by spawning a **fresh `pwsh -NoProfile` process** as shown below — never call `Invoke-Pester` directly in an existing session or via VSCode's built-in test runner.

Two reasons:
1. **Module pollution:** If modules such as `Render` or `Reducer` are already loaded in the session (from a previous run or from the VS Code extension auto-import), Pester's `InModuleScope` will find multiple copies and fail with *"Multiple script or manifest modules named '…' are currently loaded"*. A fresh `-NoProfile` process starts with no loaded modules.
2. **Thread blocking:** The VS Code built-in test runner executes inside the PowerShell Extension Host Integrated Console, which shares a thread with the Language Server. A long-running suite blocks IntelliSense and diagnostics, and can freeze VS Code entirely.

Run the full test suite from the workspace root:

```powershell
pwsh -NoProfile -Command "Import-Module Pester -Force; Invoke-Pester -Path tests\ -Output Minimal"
```

To run a single test file:

```powershell
pwsh -NoProfile -Command "Import-Module Pester -Force; Invoke-Pester -Path tests/Filtering.Tests.ps1 -Output Minimal"
```

All tests must pass after making changes. Add new tests to the appropriate file under `tests/` to lock in any new functionality.
