Set-StrictMode -Version Latest

# Import sub-modules; each handles its own internal dependencies via $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'p4\Models.psm1')    -Force
Import-Module (Join-Path $PSScriptRoot 'p4\P4Cli.psm1')     -Force
Import-Module (Join-Path $PSScriptRoot 'tui\Helpers.psm1')  -Force
Import-Module (Join-Path $PSScriptRoot 'tui\Filtering.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'tui\Layout.psm1')    -Force
Import-Module (Join-Path $PSScriptRoot 'tui\Reducer.psm1')   -Force
Import-Module (Join-Path $PSScriptRoot 'tui\Input.psm1')     -Force
Import-Module (Join-Path $PSScriptRoot 'tui\Render.psm1')    -Force -DisableNameChecking

function Get-BrowserConsoleSize {
    [pscustomobject]@{
        Width  = [Console]::WindowWidth
        Height = [Console]::WindowHeight
    }
}

function Test-BrowserConsoleKeyAvailable {
    return [Console]::KeyAvailable
}

function Read-BrowserConsoleKey {
    return [Console]::ReadKey($true)
}

function Initialize-BrowserConsole {
    $previousOutputEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

    $previousCursorVisible = [Console]::CursorVisible
    [Console]::CursorVisible = $false

    return [pscustomobject]@{
        OutputEncoding = $previousOutputEncoding
        CursorVisible  = $previousCursorVisible
    }
}

function Restore-BrowserConsole {
    param([Parameter(Mandatory = $true)]$ConsoleState)

    [Console]::CursorVisible = [bool]$ConsoleState.CursorVisible
    [Console]::OutputEncoding = $ConsoleState.OutputEncoding
    Clear-Host
}

function Invoke-BrowserSideEffect {
    <#
    .SYNOPSIS
        Wraps a p4 I/O block with CommandStart/CommandFinish modal lifecycle dispatch.
    .DESCRIPTION
        Dispatches CommandStart, renders the modal, invokes WorkItem (which performs I/O
        and returns an updated state), then dispatches CommandFinish.  Returns the final
        updated state.  On exception the modal stays open (CommandFinish Succeeded=$false).
    #>
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$CommandLine,
        [Parameter(Mandatory = $true)][scriptblock]$WorkItem
    )

    $s = Invoke-BrowserReducer -State $State -Action ([pscustomobject]@{
        Type        = 'CommandStart'
        CommandLine = $CommandLine
        StartedAt   = (Get-Date)
    })
    Render-BrowserState -State $s

    # Collect p4 observer events emitted during WorkItem execution
    $eventQueue = [System.Collections.Generic.List[pscustomobject]]::new()
    Register-P4Observer -Observer {
        param($CommandLine, $RawLines, $ExitCode, $ErrorOutput, $StartedAt, $EndedAt, $DurationMs)
        $fmt = Format-P4OutputLine -RawLines $RawLines
        $eventQueue.Add([pscustomobject]@{
            CommandLine    = $CommandLine
            FormattedLines = $fmt.FormattedLines
            OutputCount    = $fmt.OutputCount
            SummaryLine    = ''
            ExitCode       = $ExitCode
            ErrorText      = $ErrorOutput
            Succeeded      = ($ExitCode -eq 0)
            StartedAt      = $StartedAt
            EndedAt        = $EndedAt
            DurationMs     = $DurationMs
        })
    }

    $startedAt = Get-Date
    $exitCode  = 0
    $succeeded = $true
    $errorText = ''
    try {
        $s = & $WorkItem $s
    }
    catch {
        $exitCode  = 1
        $succeeded = $false
        $errorText = $_.Exception.Message
        $s.Runtime.LastError = $errorText
    }
    finally {
        Unregister-P4Observer
    }
    $endedAt = Get-Date

    # Dispatch LogCommandExecution for every p4 invocation captured by the observer
    foreach ($evt in $eventQueue) {
        $s = Invoke-BrowserReducer -State $s -Action ([pscustomobject]@{
            Type           = 'LogCommandExecution'
            CommandLine    = $evt.CommandLine
            FormattedLines = $evt.FormattedLines
            OutputCount    = $evt.OutputCount
            SummaryLine    = $evt.SummaryLine
            ExitCode       = $evt.ExitCode
            ErrorText      = $evt.ErrorText
            Succeeded      = $evt.Succeeded
            StartedAt      = $evt.StartedAt
            EndedAt        = $evt.EndedAt
            DurationMs     = $evt.DurationMs
        })
    }

    $s = Invoke-BrowserReducer -State $s -Action ([pscustomobject]@{
        Type        = 'CommandFinish'
        CommandLine = $CommandLine
        StartedAt   = $startedAt
        EndedAt     = $endedAt
        ExitCode    = $exitCode
        Succeeded   = $succeeded
        ErrorText   = $errorText
    })

    return $s
}

function ConvertTo-BrowserSubmittedFileEntries {
    param(
        [Parameter(Mandatory = $true)]$Describe,
        [Parameter(Mandatory = $true)][int]$Change
    )

    return @(
        @($Describe.Files) | ForEach-Object {
            New-P4FileEntry -DepotPath ([string]$_.DepotPath) `
                            -Action ([string]$_.Action) `
                            -FileType ([string]$_.Type) `
                            -Change $Change `
                            -SourceKind 'Submitted'
        }
    )
}

function Invoke-BrowserFilesLoad {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][int]$Change,
        [Parameter(Mandatory = $true)][string]$SourceKind,
        [Parameter(Mandatory = $true)][string]$CacheKey
    )

    switch ($SourceKind) {
        'Opened' {
            $loadFilesCmdLine = Format-P4CommandLine -P4Args @('opened', '-c', "$Change")
            return Invoke-BrowserSideEffect -State $State -CommandLine $loadFilesCmdLine -WorkItem {
                param($s)
                $files = Get-P4OpenedFiles -Change $Change
                $s.Data.FileCache[$CacheKey] = $files
                $s.Runtime.LastError = $null
                return Update-BrowserDerivedState -State $s
            }
        }
        'Submitted' {
            $loadFilesCmdLine = Format-P4CommandLine -P4Args @('describe', '-s', "$Change")
            return Invoke-BrowserSideEffect -State $State -CommandLine $loadFilesCmdLine -WorkItem {
                param($s)

                $describe = if ($s.Data.DescribeCache.ContainsKey($Change)) {
                    $s.Data.DescribeCache[$Change]
                } else {
                    $fetchedDescribe = Get-P4Describe -Change $Change
                    $s.Data.DescribeCache[$Change] = $fetchedDescribe
                    $fetchedDescribe
                }

                $s.Data.FileCache[$CacheKey] = ConvertTo-BrowserSubmittedFileEntries -Describe $describe -Change $Change
                $s.Runtime.LastError = $null
                return Update-BrowserDerivedState -State $s
            }
        }
        default {
            throw "Unsupported FilesSourceKind '$SourceKind'."
        }
    }
}

function Start-P4Browser {
    <#
    .SYNOPSIS
        Opens the Perforce TUI browser for pending changelists.
    .DESCRIPTION
        Launches an interactive terminal user interface for browsing and managing
        Perforce changelists, files, shelves, and streams. Keyboard-driven,
        Total Commander-inspired workflow.
    .PARAMETER MaxChanges
        Maximum number of pending changelists to load. Defaults to 200.
    .PARAMETER IntegrityTest
        When specified, enables the runtime frame-integrity checker.
        On every render, every row is checked for correct width and that panel
        borders sit at their expected column positions.  The first violation
        throws a terminating error immediately, halting the session so the
        offending state can be inspected.
    .EXAMPLE
        Start-P4Browser
    .EXAMPLE
        Start-P4Browser -MaxChanges 500
    .EXAMPLE
        Start-P4Browser -IntegrityTest
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [int]$MaxChanges = 200,

        [Parameter(Mandatory = $false)]
        [switch]$IntegrityTest
    )

    if ($IntegrityTest) {
        Enable-FrameIntegrityTest
    }

    $consoleSize = Get-BrowserConsoleSize
    $width  = [int]$consoleSize.Width
    $height = [int]$consoleSize.Height
    $state  = New-BrowserState -Changes @() -InitialWidth $width -InitialHeight $height

    # Phase 0.2: Store configured max for consistent reload behaviour
    $state.Runtime.ConfiguredMax = $MaxChanges

    $consoleState = Initialize-BrowserConsole

    try {
        # Populate session info from p4 info so submitted queries can be scoped
        # to the current workspace mapping from the start of the session.
        try {
            $p4Info = Get-P4Info
            $state.Data.CurrentUser = $p4Info.User
            $state.Data.CurrentClient = $p4Info.Client
        } catch {
            $state.Data.CurrentUser = ''
            $state.Data.CurrentClient = ''
        }

        # Initial load
        $loadCmdLine = "p4 changes -s pending -m $MaxChanges"
        $state = Invoke-BrowserSideEffect -State $state -CommandLine $loadCmdLine -WorkItem {
            param($s)
            $fresh = Get-P4ChangelistEntries -Max $s.Runtime.ConfiguredMax
            $s.Data.AllChanges = @($fresh)
            $s.Runtime.LastError = $null
            return Update-BrowserDerivedState -State $s
        }

        while ($state.Runtime.IsRunning) {
            Render-BrowserState -State $state

            # Poll for a keypress while also detecting console resize.
            # [Console]::ReadKey blocks indefinitely, so we use KeyAvailable +
            # a short sleep to stay responsive to window-resize events.
            $keyInfo = $null
            while ($null -eq $keyInfo) {
                if (Test-BrowserConsoleKeyAvailable) {
                    $keyInfo = Read-BrowserConsoleKey
                } else {
                    $currentSize   = Get-BrowserConsoleSize
                    $currentWidth  = [int]$currentSize.Width
                    $currentHeight = [int]$currentSize.Height
                    if ($state.Ui.Layout.Width -ne $currentWidth -or $state.Ui.Layout.Height -ne $currentHeight) {
                        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
                            Type   = 'Resize'
                            Width  = $currentWidth
                            Height = $currentHeight
                        })
                        Render-BrowserState -State $state
                    }
                    Start-Sleep -Milliseconds 50
                }
            }

            $action  = ConvertFrom-KeyInfoToAction -KeyInfo $keyInfo
            if ($null -ne $action) {
                $state = Invoke-BrowserReducer -State $state -Action $action

                # Handle reload flag (Reload I/O lives outside the reducer for purity)
                if ($state.Runtime.ReloadRequested) {
                    $state.Runtime.ReloadRequested = $false
                    $configuredMax = $state.Runtime.ConfiguredMax
                    $reloadCmdLine = "p4 changes -s pending -m $configuredMax"
                    $state = Invoke-BrowserSideEffect -State $state -CommandLine $reloadCmdLine -WorkItem {
                        param($s)
                        $fresh = Get-P4ChangelistEntries -Max $s.Runtime.ConfiguredMax
                        $s.Data.AllChanges = @($fresh)
                        $s.Runtime.LastError = $null
                        return Update-BrowserDerivedState -State $s
                    }
                }

                # Handle submitted view reload (F5 in submitted view)
                if ($state.Runtime.SubmittedReloadRequested) {
                    $state.Runtime.SubmittedReloadRequested = $false
                    $state.Runtime.LoadMoreRequested        = $false
                    $reloadSubmittedSpec = if ([string]::IsNullOrWhiteSpace([string]$state.Data.CurrentClient)) { '//...' } else { "//$($state.Data.CurrentClient)/..." }
                    $reloadSubmittedCmdLine = Format-P4CommandLine -P4Args @('changes', '-s', 'submitted', '-m', '50', $reloadSubmittedSpec)
                    $state = Invoke-BrowserSideEffect -State $state -CommandLine $reloadSubmittedCmdLine -WorkItem {
                        param($s)
                        $fresh = if ([string]::IsNullOrWhiteSpace([string]$s.Data.CurrentClient)) {
                            Get-P4SubmittedChangelistEntries -Max 50
                        } else {
                            Get-P4SubmittedChangelistEntries -Max 50 -Client $s.Data.CurrentClient
                        }
                        $s.Data.SubmittedChanges  = @($fresh)
                        $s.Data.SubmittedHasMore  = ($fresh.Count -ge 50)
                        $s.Data.SubmittedOldestId = if ($fresh.Count -gt 0) { [int]($fresh | ForEach-Object { [int]$_.Id } | Sort-Object | Select-Object -First 1) } else { $null }
                        $s.Runtime.LastError      = $null
                        return Update-BrowserDerivedState -State $s
                    }
                }

                # Handle load-more flag for submitted changelists
                if ($state.Runtime.LoadMoreRequested) {
                    $state.Runtime.LoadMoreRequested = $false
                    $beforeChange = $state.Data.SubmittedOldestId
                    $loadMoreSpec = if ([string]::IsNullOrWhiteSpace([string]$state.Data.CurrentClient)) { '//...' } else { "//$($state.Data.CurrentClient)/..." }
                    $loadMoreCmdLine = if ($null -ne $beforeChange) {
                        Format-P4CommandLine -P4Args @('changes', '-s', 'submitted', '-m', '50', "$loadMoreSpec@<$beforeChange")
                    } else {
                        Format-P4CommandLine -P4Args @('changes', '-s', 'submitted', '-m', '50', $loadMoreSpec)
                    }
                    $state = Invoke-BrowserSideEffect -State $state -CommandLine $loadMoreCmdLine -WorkItem {
                        param($s)
                        $pageSize = 50
                        $bc       = $s.Data.SubmittedOldestId
                        $newEntries = if ($null -ne $bc) {
                            if ([string]::IsNullOrWhiteSpace([string]$s.Data.CurrentClient)) {
                                @(Get-P4SubmittedChangelistEntries -Max $pageSize -BeforeChange $bc)
                            } else {
                                @(Get-P4SubmittedChangelistEntries -Max $pageSize -BeforeChange $bc -Client $s.Data.CurrentClient)
                            }
                        } else {
                            if ([string]::IsNullOrWhiteSpace([string]$s.Data.CurrentClient)) {
                                @(Get-P4SubmittedChangelistEntries -Max $pageSize)
                            } else {
                                @(Get-P4SubmittedChangelistEntries -Max $pageSize -Client $s.Data.CurrentClient)
                            }
                        }
                        $s.Data.SubmittedChanges = @($s.Data.SubmittedChanges) + @($newEntries)
                        if ($newEntries.Count -gt 0) {
                            $s.Data.SubmittedOldestId = [int]($newEntries | ForEach-Object { [int]$_.Id } | Sort-Object | Select-Object -First 1)
                        }
                        $s.Data.SubmittedHasMore = ($newEntries.Count -ge $pageSize)
                        $s.Runtime.LastError     = $null
                        return Update-BrowserDerivedState -State $s
                    }
                }

                # Handle file-list load request — I/O side effect kept outside the reducer.
                if ($state.Runtime.LoadFilesRequested) {
                    $state.Runtime.LoadFilesRequested = $false
                    $change     = [int]$state.Data.FilesSourceChange
                    $sourceKind = [string]$state.Data.FilesSourceKind
                    $cacheKey   = "${change}:${sourceKind}"

                    if ($state.Data.FileCache.ContainsKey($cacheKey)) {
                        # Cache hit — recompute derived state (cursor/scroll already reset by reducer)
                        $state = Update-BrowserDerivedState -State $state
                    } else {
                        $state = Invoke-BrowserFilesLoad -State $state -Change $change -SourceKind $sourceKind -CacheKey $cacheKey
                    }
                    # After I/O: if user navigated away, silently stay on current screen
                }

                # Fetch describe on-demand (I/O lives outside the reducer to keep it pure)
                if (-not [string]::IsNullOrWhiteSpace([string]$state.Runtime.LastSelectedId)) {
                    $change = ConvertTo-ChangeNumberFromId -Id $state.Runtime.LastSelectedId
                    $state.Runtime.LastSelectedId = $null   # consume immediately; prevents retry on every keypress
                    if ($null -ne $change -and -not $state.Data.DescribeCache.ContainsKey($change)) {
                        $describeCmdLine = Format-P4CommandLine -P4Args @('describe', '-s', "$change")
                        $state = Invoke-BrowserSideEffect -State $state -CommandLine $describeCmdLine -WorkItem {
                            param($s)
                            $s.Data.DescribeCache[$change] = Get-P4Describe -Change $change
                            $s.Runtime.LastError = $null
                            return $s
                        }
                    }
                }

                # Delete changelist on-demand
                if (-not [string]::IsNullOrWhiteSpace([string]$state.Runtime.DeleteChangeId)) {
                    $change = ConvertTo-ChangeNumberFromId -Id $state.Runtime.DeleteChangeId
                    $state.Runtime.DeleteChangeId = $null
                    if ($null -ne $change) {
                        $deleteCmdLine = Format-P4CommandLine -P4Args @('change', '-d', "$change")
                        $state = Invoke-BrowserSideEffect -State $state -CommandLine $deleteCmdLine -WorkItem {
                            param($s)
                            Remove-P4Changelist -Change $change
                            $deletedId = "$change"
                            $s.Data.AllChanges = @($s.Data.AllChanges | Where-Object { $_.Id -ne $deletedId })
                            $s.Data.DescribeCache.Remove($change) | Out-Null
                            # Remove from mark set so deleted CLs don't linger in selection
                            $markedProp = $s.Query.PSObject.Properties['MarkedChangeIds']
                            if ($null -ne $markedProp -and $null -ne $markedProp.Value) {
                                [void]$markedProp.Value.Remove($deletedId)
                            }
                            $s.Runtime.LastError = $null
                            return Update-BrowserDerivedState -State $s
                        }
                    }
                }
            }
        }
    }
    finally {
        Restore-BrowserConsole -ConsoleState $consoleState
    }
}

Export-ModuleMember -Function Start-P4Browser
