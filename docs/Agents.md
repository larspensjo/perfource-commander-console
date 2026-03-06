# General instructions how to code this project

## Architecture

* Use the Unidirectional Data flow design pattern (UDF).
* Prioritize elegance, robustness and flexibility.
* Use unit tests to lock-in functionality.
* Use the principle Correctness by Construction.
* Avoid repetition.
* Use Dependency Injection to make testing easier.
* Don't repeat yourself.
* Avoid "naked constants".

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

---

## Validating Changes

### Linter

Run PSScriptAnalyzer via the VS Code task, or directly in the terminal:

```powershell
pwsh -NoProfile -File .vscode/Invoke-Linter.ps1
```

This analyses all `.ps1`, `.psm1`, and `.psd1` files in the workspace using the settings in `PSScriptAnalyzerSettings.psd1`. Output is formatted as `file(line,col): severity rulename: message`. Fix all reported warnings and errors before committing.

### Pester Tests

**Important:** Always run Pester tests from a **terminal** (`run_in_terminal` or a
manual shell), **never** via VSCode's built-in test runner (`runTests`). The test
runner executes inside the PowerShell Extension Host's Integrated Console. That
console shares a single thread with the Language Server, so a long-running test
suite blocks IntelliSense, diagnostics, and all other LS features — and can make
VSCode appear completely frozen (triggering the "reload the window" prompt).

Run the full test suite from the workspace root:

```powershell
pwsh -NoProfile -Command "Import-Module Pester -Force; Invoke-Pester -Path tests\"
```

To run a single test file:

```powershell
pwsh -NoProfile -Command "Import-Module Pester -Force; Invoke-Pester -Path tests/Filtering.Tests.ps1"
```

All tests must pass after making changes. Add new tests to the appropriate file under `tests/` to lock in any new functionality.
