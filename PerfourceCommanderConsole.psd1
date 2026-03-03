@{
    # Module identity
    RootModule        = 'PerfourceCommanderConsole.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'af394067-3440-4779-afbd-17e1d494223d'

    # Authoring metadata
    Author            = ''
    CompanyName       = ''
    Copyright         = ''
    Description       = 'Perforce (p4) terminal user interface for browsing and managing changelists, files, shelves, and streams. Total Commander-inspired, keyboard-driven, built as a wrapper around p4.exe.'

    # Requirements
    PowerShellVersion = '7.0'

    # Public API — only Start-P4Browser is exported; internal sub-module functions
    # are consumed by the root module but are not part of the public surface.
    FunctionsToExport = @('Start-P4Browser')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    # Module files that ship with this module (informational)
    FileList = @(
        'PerfourceCommanderConsole.psd1',
        'PerfourceCommanderConsole.psm1',
        'Browse-P4.ps1',
        'p4\Models.psm1',
        'p4\P4Cli.psm1',
        'tui\Filtering.psm1',
        'tui\Input.psm1',
        'tui\Layout.psm1',
        'tui\Reducer.psm1',
        'tui\Render.psm1'
    )

    PrivateData = @{
        PSData = @{
            Tags         = @('Perforce', 'p4', 'TUI', 'CLI', 'Changelist')
            ProjectUri   = ''
            LicenseUri   = ''
            ReleaseNotes = 'Initial release.'
        }
    }
}
