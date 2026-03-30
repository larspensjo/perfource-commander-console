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

Some functions (e.g. `Merge-AdjacentSegments`) return an array **as a single value** via `Write-Output -NoEnumerate`. Wrapping in `@()` silently produces a 1-element nested array with no error.

```powershell
# WRONG — Count=1, nested array
$segs = @(Merge-AdjacentSegments -Segments $input)
# CORRECT
$segs = Merge-AdjacentSegments -Segments $input
```

Mark such functions with `# Returns array-as-value; do NOT wrap call in @()`.

### Normalize 0..N results at call boundaries

PowerShell turns an empty result into `$null`. Always normalize with `@(...)` when a function can return zero items.

```powershell
# WRONG — $files is $null when no items returned
$files = Get-P4OpenedFiles -Change $Change
# CORRECT
$files = @(Get-P4OpenedFiles -Change $Change)
```

* Use `[AllowEmptyCollection()]` (and `[AllowNull()]` where appropriate) on collection parameters.
* Apply especially at I/O boundaries: `Invoke-P4`, file-cache writes, parser helpers.

### `Import-Module` inside a `.psm1` must use `-Global`

Without `-Global`, the imported module becomes a private nested module and disappears from the global session — its functions become invisible to all other callers including tests.

```powershell
# WRONG
Import-Module (Join-Path $PSScriptRoot 'Models.psm1') -Force
# CORRECT
Import-Module (Join-Path $PSScriptRoot 'Models.psm1') -Force -Global
```

### `(if ...)` is invalid in argument position

PowerShell parses `if` as a command name inside a call. Pre-compute to a variable.

```powershell
# WRONG
New-Thing -Action (if ($cond) { 'x' } else { 'y' })
# CORRECT
$action = if ($cond) { 'x' } else { 'y' }
New-Thing -Action $action
```

### Empty-array pipeline collapse from `if` expressions

`if`/`else` returning `@()` collapses to `$null` in the pipeline; `.Count` then throws under `Set-StrictMode`.

```powershell
# WRONG — $rows may be $null
$rows = if ($cond) { @($source) } else { @() }
# CORRECT
$rows = @()
if ($cond) { $rows = @($source) }
```

### Avoid pipeline scriptblocks over nullable scalars

When a collection can contain `$null` or `''`, avoid piping it into `ForEach-Object` with expressions like `$_ -match ...`. In PowerShell, `.NET null` values flowing through a pipeline scriptblock can trigger surprising `NullReferenceException` failures instead of behaving like ordinary `$null` checks.

```powershell
# WRONG — crashes if any element is a .NET null
$quoted = $args | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }

# CORRECT
$quoted = foreach ($arg in $args) {
    if ($null -ne $arg -and $arg -ne '') {
        if ($arg -match '\s') { '"' + $arg + '"' } else { $arg }
    }
}
```

Use a `foreach` loop when normalizing command arguments, rendering segments, or other scalar collections that may carry placeholders or optional values.

### Pester 5 test file structure — per-`Describe` `BeforeAll`

Top-level code runs only during **discovery**, not execution. Functions defined at the top level are invisible inside `It`/`BeforeEach`.

```powershell
# Every Describe that calls module functions needs:
Describe 'Foo' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\MyModule.psm1') -Force -Global
        function script:New-Helper { ... }  # helpers also go here
    }
    It 'works' { New-Helper }
}
```

Top-level `Import-Module -Force -Global` is for IDE tooling only — do not rely on it for test execution.

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
