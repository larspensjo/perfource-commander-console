Set-StrictMode -Version Latest

# Import sub-modules; each handles its own internal dependencies via $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'p4\Models.psm1')    -Force
Import-Module (Join-Path $PSScriptRoot 'p4\P4Cli.psm1')     -Force
Import-Module (Join-Path $PSScriptRoot 'tui\Helpers.psm1')  -Force
Import-Module (Join-Path $PSScriptRoot 'tui\Theme.psm1')    -Force
Import-Module (Join-Path $PSScriptRoot 'tui\Filtering.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'tui\Layout.psm1')    -Force
Import-Module (Join-Path $PSScriptRoot 'tui\Reducer.psm1')   -Force
Import-Module (Join-Path $PSScriptRoot 'tui\Input.psm1')     -Force
Import-Module (Join-Path $PSScriptRoot 'tui\Render.psm1')    -Force -DisableNameChecking

# Workflow registry: Kind (string) → executor scriptblock.
# Executors receive -State and -Request parameters and must return the updated state.
# They are responsible for dispatching WorkflowBegin, WorkflowItemComplete/Failed, and WorkflowEnd.
$script:WorkflowRegistry = @{}

function Register-WorkflowKind {
    <#
    .SYNOPSIS
        Registers an executor for a named workflow kind.  Call this at module
        load time or before Start-P4Browser to add supported workflow kinds.
    .PARAMETER Kind
        Unique workflow identifier string, e.g. 'DeleteMarked'.
    .PARAMETER Execute
        Scriptblock that performs the workflow.  Receives -State and -Request
        parameters, dispatches progress actions, and returns the final state.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][scriptblock]$Execute
    )
    $script:WorkflowRegistry[$Kind] = $Execute
}

# ── Built-in workflow executors ───────────────────────────────────────────────

Register-WorkflowKind -Kind 'DeleteMarked' -Execute {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$State,
        [Parameter(Mandatory = $true)][pscustomobject]$Request
    )

    [string[]]$changeIds = @($Request.ChangeIds)
    $state = Invoke-BrowserReducer -State $State -Action ([pscustomobject]@{
        Type = 'WorkflowBegin'; Kind = 'DeleteMarked'; TotalCount = $changeIds.Count
    })

    $successIds = [System.Collections.Generic.List[string]]::new()
    $lastFailureError = ''

    foreach ($changeId in $changeIds) {
        $changeNum = [string]$changeId
        $deleteCmdLine = Format-P4CommandLine -P4Args @('change', '-d', "$changeNum")
        $result = Invoke-BrowserWorkflowCommand -State $state -CommandLine $deleteCmdLine -WorkItem {
            param($s)
            Remove-P4Changelist -Change $changeNum
            return $s
        }
        $state = $result.State

        if ($result.Succeeded) {
            $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'WorkflowItemComplete' })
            [void]$successIds.Add($changeId)
        } else {
            if (-not [string]::IsNullOrWhiteSpace([string]$result.ErrorText)) {
                $lastFailureError = [string]$result.ErrorText
            }
            $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
                Type = 'WorkflowItemFailed'; ChangeId = $changeId
            })
        }
    }

    # Remove successfully deleted IDs from the mark set immediately (before reload)
    foreach ($id in $successIds) {
        [void]$state.Query.MarkedChangeIds.Remove($id)
    }

    $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'WorkflowEnd' })

    # Trigger a fresh reload so AllChanges reflects reality
    $state = Invoke-BrowserPendingChangesReload -State $state
    if (-not [string]::IsNullOrWhiteSpace($lastFailureError)) {
        $state.Runtime.LastError = $lastFailureError
    }

    return $state
}

Register-WorkflowKind -Kind 'MoveMarkedFiles' -Execute {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$State,
        [Parameter(Mandatory = $true)][pscustomobject]$Request
    )

    [string[]]$changeIds  = @($Request.ChangeIds)
    [string]$targetId     = [string]$Request.TargetChangeId
    [string]$targetChange = $targetId

    $state = Invoke-BrowserReducer -State $State -Action ([pscustomobject]@{
        Type = 'WorkflowBegin'; Kind = 'MoveMarkedFiles'; TotalCount = $changeIds.Count
    })

    $successIds = [System.Collections.Generic.List[string]]::new()
    $lastFailureError = ''

    foreach ($changeId in $changeIds) {
        # Skip source == target to avoid a no-op p4 reopen call
        if ($changeId -eq $targetId) {
            $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'WorkflowItemComplete' })
            [void]$successIds.Add($changeId)
            continue
        }

        $sourceChange  = [string]$changeId
        $reopenCmdLine = Format-P4CommandLine -P4Args @('reopen', '-c', $targetChange, '//...')
        $result = Invoke-BrowserWorkflowCommand -State $state -CommandLine $reopenCmdLine -WorkItem {
            param($s)
            Invoke-P4ReopenFiles -SourceChange $sourceChange -TargetChange $targetChange | Out-Null
            return $s
        }
        $state = $result.State

        if ($result.Succeeded) {
            $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'WorkflowItemComplete' })
            [void]$successIds.Add($changeId)
        } else {
            if (-not [string]::IsNullOrWhiteSpace([string]$result.ErrorText)) {
                $lastFailureError = [string]$result.ErrorText
            }
            $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
                Type = 'WorkflowItemFailed'; ChangeId = $changeId
            })
        }
    }

    # Unmark successfully processed source changelists
    foreach ($id in $successIds) {
        [void]$state.Query.MarkedChangeIds.Remove($id)
    }

    $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'WorkflowEnd' })

    # Trigger reload so HasOpenedFiles and counts are re-fetched
    $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'Reload' })

    if (-not [string]::IsNullOrWhiteSpace($lastFailureError)) {
        $state.Runtime.LastError = $lastFailureError
    }

    return $state
}

Register-WorkflowKind -Kind 'ShelveFiles' -Execute {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$State,
        [Parameter(Mandatory = $true)][pscustomobject]$Request
    )

    [string[]]$changeIds = @($Request.ChangeIds)
    $state = Invoke-BrowserReducer -State $State -Action ([pscustomobject]@{
        Type = 'WorkflowBegin'; Kind = 'ShelveFiles'; TotalCount = $changeIds.Count
    })

    $lastFailureError = ''

    foreach ($changeId in $changeIds) {
        $changeNum = [string]$changeId
        $shelveCmdLine = Format-P4CommandLine -P4Args @('shelve', '-f', '-c', "$changeNum")
        $result = Invoke-BrowserWorkflowCommand -State $state -CommandLine $shelveCmdLine -WorkItem {
            param($s)
            Invoke-P4ShelveFiles -Change $changeNum
            return $s
        }
        $state = $result.State

        if ($result.Succeeded) {
            $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'WorkflowItemComplete' })
        } else {
            if (-not [string]::IsNullOrWhiteSpace([string]$result.ErrorText)) {
                $lastFailureError = [string]$result.ErrorText
            }
            $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
                Type = 'WorkflowItemFailed'; ChangeId = $changeId
            })
        }
    }

    $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'WorkflowEnd' })

    # Trigger reload so shelved file counts are refreshed
    $state = Invoke-BrowserPendingChangesReload -State $state
    if (-not [string]::IsNullOrWhiteSpace($lastFailureError)) {
        $state.Runtime.LastError = $lastFailureError
    }

    return $state
}

Register-WorkflowKind -Kind 'DeleteShelvedFiles' -Execute {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$State,
        [Parameter(Mandatory = $true)][pscustomobject]$Request
    )

    [string[]]$changeIds = @($Request.ChangeIds)
    $state = Invoke-BrowserReducer -State $State -Action ([pscustomobject]@{
        Type = 'WorkflowBegin'; Kind = 'DeleteShelvedFiles'; TotalCount = $changeIds.Count
    })

    $lastFailureError = ''

    foreach ($changeId in $changeIds) {
        $changeNum = [string]$changeId
        $deleteShelvedCmdLine = Format-P4CommandLine -P4Args @('shelve', '-d', '-c', "$changeNum")
        $result = Invoke-BrowserWorkflowCommand -State $state -CommandLine $deleteShelvedCmdLine -WorkItem {
            param($s)
            Remove-P4ShelvedFiles -Change $changeNum
            return $s
        }
        $state = $result.State

        if ($result.Succeeded) {
            $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'WorkflowItemComplete' })
        } else {
            if (-not [string]::IsNullOrWhiteSpace([string]$result.ErrorText)) {
                $lastFailureError = [string]$result.ErrorText
            }
            $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
                Type = 'WorkflowItemFailed'; ChangeId = $changeId
            })
        }
    }

    $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'WorkflowEnd' })

    $state = Invoke-BrowserPendingChangesReload -State $state
    if (-not [string]::IsNullOrWhiteSpace($lastFailureError)) {
        $state.Runtime.LastError = $lastFailureError
    }

    return $state
}

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

# ── Shared command-result helpers (M0.3, M0.5) ───────────────────────────────

function New-BrowserCommandRecord {
    <#
    .SYNOPSIS
        Creates a standardized command-result record (M0.3).
    .DESCRIPTION
        Returns a [pscustomobject] with a consistent set of fields representing one
        completed p4 command execution.  All callers that produce a command result
        use this factory so the shape is defined in exactly one place.
    #>
    param(
        [Parameter(Mandatory)][string]$CommandLine,
        [Parameter(Mandatory)][bool]$Succeeded,
        [int]$ExitCode        = 0,
        [string]$ErrorText    = '',
        [object[]]$Output     = @(),
        [datetime]$StartedAt  = [datetime]::MinValue,
        [datetime]$EndedAt    = [datetime]::MinValue
    )
    $durationMs = if ($StartedAt -ne [datetime]::MinValue -and $EndedAt -ne [datetime]::MinValue) {
        [int](($EndedAt - $StartedAt).TotalMilliseconds)
    } else { 0 }

    return [pscustomobject]@{
        CommandLine = $CommandLine
        Succeeded   = $Succeeded
        ExitCode    = if ($Succeeded -and $ExitCode -eq 0) { 0 } else { $ExitCode }
        ErrorText   = $ErrorText
        Output      = @($Output)
        StartedAt   = $StartedAt
        EndedAt     = $EndedAt
        DurationMs  = $durationMs
    }
}

function New-BrowserSyncExecutor {
    <#
    .SYNOPSIS
        Returns the sync-executor scriptblock used by workflow steps (M0.5).
    .DESCRIPTION
        This is a DI seam: callers pass an optional -Override scriptblock; when
        null, the production executor (Invoke-BrowserSideEffect) is returned.
        Tests inject a lightweight stub here so workflow logic can be validated
        without real I/O.

        The returned scriptblock has the signature:
            param([pscustomobject]$State, [string]$CommandLine, [scriptblock]$WorkItem)
        and must return an updated state object.
    .PARAMETER Override
        Optional replacement executor.  Must accept ($State, $CommandLine, $WorkItem)
        and return an updated [pscustomobject] state.  Pass $null to get the
        production executor.
    #>
    param([scriptblock]$Override = $null)

    if ($null -ne $Override) { return $Override }

    return {
        param($State, $CommandLine, $WorkItem)
        return Invoke-BrowserSideEffect -State $State -CommandLine $CommandLine -WorkItem $WorkItem
    }
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

    $commandTimeoutMs = Get-P4CommandTimeout -CommandLine $CommandLine
    $s = Invoke-BrowserReducer -State $State -Action ([pscustomobject]@{
        Type        = 'CommandStart'
        CommandLine = $CommandLine
        TimeoutMs   = $commandTimeoutMs
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
        $evtDurationClass = Get-DurationClass -DurationMs ([int]$evt.DurationMs)
        $evtOutcome       = if ([bool]$evt.Succeeded) { 'Completed' } else { 'Failed' }
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
            DurationClass  = $evtDurationClass
            Outcome        = $evtOutcome
        })
    }

    $outerDurationMs    = [int](($endedAt - $startedAt).TotalMilliseconds)
    $outerDurationClass = Get-DurationClass -DurationMs $outerDurationMs
    $outerOutcome       = if ($succeeded) { 'Completed' } else { 'Failed' }
    $s = Invoke-BrowserReducer -State $s -Action ([pscustomobject]@{
        Type          = 'CommandFinish'
        CommandLine   = $CommandLine
        StartedAt     = $startedAt
        EndedAt       = $endedAt
        ExitCode      = $exitCode
        Succeeded     = $succeeded
        ErrorText     = $errorText
        DurationClass = $outerDurationClass
        Outcome       = $outerOutcome
    })

    return $s
}

function ConvertTo-BrowserSubmittedFileEntries {
    param(
        [Parameter(Mandatory = $true)]$Describe,
        [Parameter(Mandatory = $true)][string]$Change
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
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'CacheKey',
        Justification = 'CacheKey is captured by the WorkItem scriptblock closures below.')]
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$Change,
        [Parameter(Mandatory = $true)][string]$SourceKind,
        [Parameter(Mandatory = $true)][string]$CacheKey
    )

    switch ($SourceKind) {
        'Opened' {
            $loadFilesCmdLine = Format-P4CommandLine -P4Args @(
                'fstat',
                '-Ro',
                '-e', "$Change",
                '-T', 'change,depotFile,action,type,unresolved',
                '//...'
            )
            return Invoke-BrowserSideEffect -State $State -CommandLine $loadFilesCmdLine -WorkItem {
                param($s)
                $files = @(Get-P4OpenedFiles -Change $Change)
                $s.Data.FileCache[$CacheKey]       = $files
                $s.Data.FileCacheStatus[$CacheKey] = 'BaseReady'
                $s.Runtime.LastError = $null
                # Signal enrichment as a follow-up (diff -sa) — M2.1
                $s.Runtime.PendingRequest = New-PendingRequest @{ Kind = 'LoadFilesEnrichment'; CacheKey = $CacheKey } -Generation $s.Data.FilesGeneration
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

function Invoke-BrowserFilesEnrichment {
    <#
    .SYNOPSIS
        Runs content-diff enrichment (p4 diff -sa) on a base-loaded file cache entry.
    .DESCRIPTION
        Called after Invoke-BrowserFilesLoad has stored base fstat data with
        FileCacheStatus = 'BaseReady'. Fetches modified depot paths and merges
        IsContentModified into each FileEntry. Sets FileCacheStatus to 'Ready'
        on success or 'EnrichmentFailed' on error.  Idempotent: a no-op when
        status is already 'LoadingEnrichment' or 'Ready' (M2.4).
    #>
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'CacheKey',
        Justification = 'CacheKey is captured by the WorkItem scriptblock closure below.')]
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$CacheKey
    )

    # Idempotence check (M2.4): skip if already enriching or done.
    $currentStatus = if ($State.Data.FileCacheStatus.ContainsKey($CacheKey)) {
        [string]$State.Data.FileCacheStatus[$CacheKey]
    } else {
        'NotLoaded'
    }
    if ($currentStatus -in @('LoadingEnrichment', 'Ready')) {
        return $State
    }

    # If the base data has not been loaded there is nothing to enrich.
    if (-not $State.Data.FileCache.ContainsKey($CacheKey)) {
        return $State
    }

    $enrichCmdLine = Format-P4CommandLine -P4Args @('diff', '-sa')
    return Invoke-BrowserSideEffect -State $State -CommandLine $enrichCmdLine -WorkItem {
        param($s)
        [object[]]$existingFiles = @($s.Data.FileCache[$CacheKey])
        $s.Data.FileCacheStatus[$CacheKey] = 'LoadingEnrichment'
        try {
            $modifiedPaths = Get-P4ModifiedDepotPaths -FileEntries $existingFiles
            $enrichedFiles = Set-P4FileEntriesContentModifiedState -FileEntries $existingFiles -ModifiedDepotPaths $modifiedPaths
            $s.Data.FileCache[$CacheKey]       = $enrichedFiles
            $s.Data.FileCacheStatus[$CacheKey] = 'Ready'
        }
        catch {
            $s.Data.FileCacheStatus[$CacheKey] = 'EnrichmentFailed'
            $s.Runtime.LastError = [string]$_.Exception.Message
        }
        return Update-BrowserDerivedState -State $s
    }
}

function Invoke-BrowserWorkflowCommand {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$CommandLine,
        [Parameter(Mandatory = $true)][scriptblock]$WorkItem
    )

    $nextState = Invoke-BrowserSideEffect -State $State -CommandLine $CommandLine -WorkItem $WorkItem
    [object[]]$history = @($nextState.Runtime.ModalPrompt.History)
    $historyItem = if ($history.Count -gt 0) { $history[0] } else { $null }
    $matchesCommand = $null -ne $historyItem -and [string]::Equals([string]$historyItem.CommandLine, $CommandLine, [System.StringComparison]::Ordinal)

    return [pscustomobject]@{
        State     = $nextState
        Succeeded = ($matchesCommand -and [bool]$historyItem.Succeeded)
        ErrorText = if ($matchesCommand) { [string]$historyItem.ErrorText } else { [string]$nextState.Runtime.LastError }
    }
}

function Invoke-BrowserPendingChangesReload {
    param(
        [Parameter(Mandatory = $true)]$State
    )

    $configuredMax = $State.Runtime.ConfiguredMax
    $reloadCmdLine = "p4 changes -s pending -m $configuredMax"
    return Invoke-BrowserSideEffect -State $State -CommandLine $reloadCmdLine -WorkItem {
        param($s)
        $fresh = Get-P4ChangelistEntries -Max $s.Runtime.ConfiguredMax
        $s.Data.AllChanges = @($fresh)
        $s.Runtime.LastError = $null
        $s = Invoke-BrowserReducer -State $s -Action ([pscustomobject]@{
            Type         = 'ReconcileMarks'
            AllChangeIds = @($fresh | ForEach-Object { [string]$_.Id })
        })
        return Update-BrowserDerivedState -State $s
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
        $state = Invoke-BrowserSideEffect -State $state -CommandLine 'p4 info' -WorkItem {
            param($s)
            $p4Info = Get-P4Info
            $s.Data.CurrentUser   = $p4Info.User
            $s.Data.CurrentClient = $p4Info.Client
            return $s
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

            $action  = ConvertFrom-KeyInfoToAction -KeyInfo $keyInfo -State $state
            if ($null -ne $action) {
                $state = Invoke-BrowserReducer -State $state -Action $action

                # Dispatch single PendingRequest (I/O side effects live outside the reducer)
                if ($null -ne $state.Runtime.PendingRequest) {
                    $req = $state.Runtime.PendingRequest
                    $state.Runtime.PendingRequest = $null   # consume before I/O so retries never re-fire

                    switch ($req.Kind) {
                        'ReloadPending' {
                            $state = Invoke-BrowserPendingChangesReload -State $state
                        }
                        'ReloadSubmitted' {
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
                                $s = Invoke-BrowserReducer -State $s -Action ([pscustomobject]@{
                                    Type         = 'ReconcileMarks'
                                    AllChangeIds = @($fresh | ForEach-Object { [string]$_.Id })
                                })
                                return Update-BrowserDerivedState -State $s
                            }
                        }
                        'LoadMore' {
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
                        'LoadFiles' {
                            $change     = [string]$state.Data.FilesSourceChange
                            $sourceKind = [string]$state.Data.FilesSourceKind
                            $cacheKey   = "${change}:${sourceKind}"

                            if ($state.Data.FileCache.ContainsKey($cacheKey)) {
                                # Cache hit — recompute derived state (cursor/scroll already reset by reducer)
                                $state = Update-BrowserDerivedState -State $state
                                # If base data exists but enrichment hasn't run yet, trigger it now (M2.4).
                                $cacheStatus = if ($state.Data.FileCacheStatus.ContainsKey($cacheKey)) { [string]$state.Data.FileCacheStatus[$cacheKey] } else { 'NotLoaded' }
                                if ($cacheStatus -eq 'BaseReady') {
                                    $state = Invoke-BrowserFilesEnrichment -State $state -CacheKey $cacheKey
                                }
                            } else {
                                $state = Invoke-BrowserFilesLoad -State $state -Change $change -SourceKind $sourceKind -CacheKey $cacheKey
                            }
                            # After I/O: if user navigated away, silently stay on current screen
                        }
                        'LoadFilesEnrichment' {
                            # Run content-diff enrichment (diff -sa) after base fstat load (M2.1).
                            $cacheKey = [string]$req.CacheKey
                            $state = Invoke-BrowserFilesEnrichment -State $state -CacheKey $cacheKey
                        }
                        'FetchDescribe' {
                            $change = ConvertTo-P4ChangelistId -Value $req.ChangeId
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
                        'DeleteChange' {
                            $change = ConvertTo-P4ChangelistId -Value $req.ChangeId
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
                        'DeleteShelvedFiles' {
                            $change = ConvertTo-P4ChangelistId -Value $req.ChangeId
                            if ($null -ne $change) {
                                $deleteShelvedCmdLine = Format-P4CommandLine -P4Args @('shelve', '-d', '-c', "$change")
                                $state = Invoke-BrowserSideEffect -State $state -CommandLine $deleteShelvedCmdLine -WorkItem {
                                    param($s)
                                    Remove-P4ShelvedFiles -Change $change
                                    $s.Runtime.LastError = $null
                                    return $s
                                }
                                $state = Invoke-BrowserPendingChangesReload -State $state
                            }
                        }
                        'ExecuteWorkflow' {
                            $workflowKind = if (($req.PSObject.Properties.Match('WorkflowKind')).Count -gt 0) { [string]$req.WorkflowKind } else { '' }
                            if ([string]::IsNullOrEmpty($workflowKind) -or -not $script:WorkflowRegistry.ContainsKey($workflowKind)) {
                                throw "Unknown workflow kind: '$workflowKind'"
                            }
                            $executor = $script:WorkflowRegistry[$workflowKind]
                            # Executor receives state + request, dispatches BeginWorkflow/ItemComplete/Failed/End, returns final state
                            $state = & $executor -State $state -Request $req
                        }
                        default {
                            throw "Unknown PendingRequest.Kind: '$($req.Kind)'"
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

Export-ModuleMember -Function Start-P4Browser, Register-WorkflowKind
