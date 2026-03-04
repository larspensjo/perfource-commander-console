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
