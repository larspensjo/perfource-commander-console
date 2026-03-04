# General instructions how to code this project

## Architecture

* Use the Unid Directional Data flow design pattern.
* Prioritize elegance, robustness and flexibility.
* Use unit tests to lock-in functionality.
* Use the principle Correctness by Construction.
* Avoid repetition.
* Use Dependency Injection to make testing easier.

## Workflows

* When a bug is found or fixed, analyze the lessons learned. If there is a robustness issue, investigate if there is a change that can prevent future problems of the same type to recur.

## PowerShell 5.1 Compatibility

This project runs on Windows PowerShell 5.1. Keep the following constraints in mind when editing any `.ps1` / `.psm1` file:

* **UTF-8 BOM required.** PowerShell 5.1 reads files as Windows-1252 unless the file starts with a UTF-8 BOM (`EF BB BF`). Any file that contains non-ASCII characters (box-drawing glyphs, arrows, accented letters, etc.) **must** be saved as *UTF-8 with BOM*. Files that are pure ASCII are safe without a BOM. When creating or rewriting such a file via a tool that writes UTF-8 without BOM, prepend the BOM explicitly or use `[System.IO.File]::WriteAllText` / `-Encoding utf8` with BOM support. Missing BOMs cause silent mojibake that breaks string comparisons at runtime and is hard to detect.
* **No `Sort-Object -Stable`.** The `-Stable` flag was added in PowerShell 6. Use a secondary sort key to get deterministic ordering instead.
* **No `[datetime]::UnixEpoch`.** Use `[datetime]::new(1970,1,1,0,0,0,[DateTimeKind]::Utc)` as the epoch constant.

## Validating Changes

### Linter

Run PSScriptAnalyzer via the VS Code task, or directly in the terminal:

```powershell
pwsh -NoProfile -File .vscode/Invoke-Linter.ps1
```

This analyses all `.ps1`, `.psm1`, and `.psd1` files in the workspace using the settings in `PSScriptAnalyzerSettings.psd1`. Output is formatted as `file(line,col): severity rulename: message`. Fix all reported warnings and errors before committing.

### Pester Tests

Run the full test suite from the workspace root:

```powershell
Invoke-Pester tests/
```

To run a single test file:

```powershell
Invoke-Pester tests/Filtering.Tests.ps1
```

All tests must pass after making changes. Add new tests to the appropriate file under `tests/` to lock in any new functionality.
