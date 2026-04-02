# perfource-commander-console
Perforce (p4) terminal user interface (TUI) for browsing and managing changelists, files, shelves, and streams—Total Commander–inspired, fast keyboard-driven workflow, built as a wrapper around p4.exe.

## Requirements

* PowerShell 7.0 or newer (`pwsh`)
* `p4.exe` available on PATH

## Diagnostics

Run `Browse-P4.ps1 -Profile -ProfilePath <path>` to write a JSON Lines diagnostic log. The profile includes UI timing data and async process-management events such as request start, process start/finish, cancellation, and kill attempts.
