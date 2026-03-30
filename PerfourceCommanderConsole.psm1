Set-StrictMode -Version Latest

# Import sub-modules; each handles its own internal dependencies via $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'p4\Models.psm1')    -Force
Import-Module (Join-Path $PSScriptRoot 'p4\P4Cli.psm1')     -Force
Import-Module (Join-Path $PSScriptRoot 'tui\Helpers.psm1')  -Force -Global
Import-Module (Join-Path $PSScriptRoot 'tui\Theme.psm1')    -Force -Global
Import-Module (Join-Path $PSScriptRoot 'tui\Filtering.psm1') -Force -Global
Import-Module (Join-Path $PSScriptRoot 'tui\Layout.psm1')    -Force -Global
Import-Module (Join-Path $PSScriptRoot 'tui\Reducer.psm1')   -Force -Global
Import-Module (Join-Path $PSScriptRoot 'tui\GraphReducer.psm1') -Force -Global
Import-Module (Join-Path $PSScriptRoot 'tui\Input.psm1')     -Force -Global
Import-Module (Join-Path $PSScriptRoot 'tui\Render.psm1')    -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'tui\GraphRender.psm1') -Force -Global -DisableNameChecking

# Workflow registry: Kind (string) → executor scriptblock.
# Executors receive -State and -Request parameters and must return the updated state.
# They are responsible for dispatching WorkflowBegin, WorkflowItemComplete/Failed, and WorkflowEnd.
$script:WorkflowRegistry = @{}

# ── Cancel-check injection (M3.3) ─────────────────────────────────────────────
# Default: poll console keys; return 'Cancel', 'Quit', or 'Continue'.
# Tests override this via Set-BrowserCheckCancelCallback.
$script:CheckCancelCallback = {
    param($State)
    try {
        while ([Console]::KeyAvailable) {
            $key    = [Console]::ReadKey($true)
            $action = ConvertFrom-KeyInfoToAction -KeyInfo $key -State $State
            if ($null -ne $action) {
                if ($action.Type -eq 'HideCommandModal') { return 'Cancel' }
                if ($action.Type -eq 'Quit')             { return 'Quit'   }
            }
        }
    } catch {
        return 'Continue'
    }
    return 'Continue'
}

function Set-BrowserCheckCancelCallback {
    <#
    .SYNOPSIS
        Replaces the between-item cancel-check callback (M3.3).
    .DESCRIPTION
        The production callback polls [Console]::KeyAvailable.  In tests, inject a
        deterministic scriptblock that returns a fixed sequence of 'Cancel', 'Quit',
        or 'Continue' without touching the console.
    #>
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Callback
    )
    $script:CheckCancelCallback = $Callback
}

# ── Async executor (M4.2) ─────────────────────────────────────────────────────
# Job registry: RequestId (string) → job handle (ThreadJob or pre-computed result for tests)
$script:AsyncJobRegistry  = @{}
$script:AsyncWorkflowContext = $null
$script:AsyncMutationWorkflowKinds = @('DeleteMarked', 'DeleteShelvedFiles', 'ShelveFiles', 'MoveMarkedFiles')
# Module root for background worker imports
$script:AsyncModuleRoot   = $PSScriptRoot

# Production executor: runs work in an isolated Start-ThreadJob runspace.
# Tests override this via Set-BrowserAsyncExecutor with a synchronous executor.
$script:AsyncExecutor = [pscustomobject]@{
    Execute = {
        param([pscustomobject]$Envelope, [scriptblock]$Worker)
        $envProps = @{}
        foreach ($prop in $Envelope.PSObject.Properties) { $envProps[$prop.Name] = $prop.Value }
        $eventFile = [System.IO.Path]::GetTempFileName()
        $envProps['ProcessEventFile'] = $eventFile
        # Capture the calling directory so the ThreadJob (which starts in an
        # independent runspace with an unrelated $PWD) runs p4.exe from within
        # the workspace.  Without this, 'p4 describe' and similar commands fail
        # when the runspace's $PWD has no Perforce client mapping.
        $capturedDir    = (Get-Location).Path
        $capturedWorker = $Worker
        $job = Start-ThreadJob -ScriptBlock {
            param([pscustomobject]$Envelope, [string]$ModuleRoot)
            if (-not [string]::IsNullOrEmpty($using:capturedDir)) {
                try { Set-Location -LiteralPath $using:capturedDir -ErrorAction SilentlyContinue } catch {}
            }
            & $using:capturedWorker $Envelope $ModuleRoot
        } -ArgumentList ([pscustomobject]$envProps), $script:AsyncModuleRoot
        $script:AsyncJobRegistry[[string]$Envelope.RequestId] = [pscustomobject]@{
            Job               = $job
            ProcessEventFile  = $eventFile
            LastEventLineRead = 0
            ActiveProcessIds  = @()
        }
    }
    Poll = {
        param([string]$RequestId)
        $entry = $script:AsyncJobRegistry[$RequestId]
        if ($null -eq $entry)                                        { return $null }
        $job = if ($entry -is [System.Management.Automation.Job]) { $entry } elseif (($entry.PSObject.Properties.Match('Job')).Count -gt 0) { $entry.Job } else { $null }
        if ($null -eq $job)                                          { return $null }
        if ($job -isnot [System.Management.Automation.Job])         { return $null }
        if ($job.State -notin @('Completed', 'Failed', 'Stopped'))  { return $null }
        $result = $job | Receive-Job -Wait -ErrorAction SilentlyContinue
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        if ($null -ne $entry -and ($entry.PSObject.Properties.Match('ProcessEventFile')).Count -gt 0) {
            $eventFile = [string]$entry.ProcessEventFile
            if (-not [string]::IsNullOrWhiteSpace($eventFile) -and (Test-Path -LiteralPath $eventFile)) {
                Remove-Item -LiteralPath $eventFile -Force -ErrorAction SilentlyContinue
            }
        }
        [void]$script:AsyncJobRegistry.Remove($RequestId)
        return $result
    }
    Cancel = {
        param([string]$RequestId)
        $entry = $script:AsyncJobRegistry[$RequestId]
        $job = if ($entry -is [System.Management.Automation.Job]) { $entry } elseif ($null -ne $entry -and ($entry.PSObject.Properties.Match('Job')).Count -gt 0) { $entry.Job } else { $null }
        if ($null -ne $job -and $job -is [System.Management.Automation.Job]) {
            try { Stop-Job  -Job $job }         catch {}
            try { Remove-Job -Job $job -Force } catch {}
        }
        if ($null -ne $entry -and ($entry.PSObject.Properties.Match('ProcessEventFile')).Count -gt 0) {
            $eventFile = [string]$entry.ProcessEventFile
            if (-not [string]::IsNullOrWhiteSpace($eventFile) -and (Test-Path -LiteralPath $eventFile)) {
                Remove-Item -LiteralPath $eventFile -Force -ErrorAction SilentlyContinue
            }
        }
        [void]$script:AsyncJobRegistry.Remove($RequestId)
    }
}

function Set-BrowserAsyncExecutor {
    <#
    .SYNOPSIS
        Replaces the async executor with a test double (M4.2 DI seam).
    .DESCRIPTION
        The production executor uses Start-ThreadJob.  Tests inject a synchronous
        executor that runs work inline so that mocked p4 functions are visible and
        completions are available immediately on the first Poll call.
    #>
    param([Parameter(Mandatory = $true)]$Executor)
    $script:AsyncExecutor = $Executor
}

function New-BrowserProfiler {
    param(
        [Parameter(Mandatory = $false)][bool]$Enabled = $false,
        [Parameter(Mandatory = $false)][string]$Path = '',
        [Parameter(Mandatory = $false)][int]$ThresholdMs = 20
    )

    if (-not $Enabled) {
        return [pscustomobject]@{
            Enabled     = $false
            Path        = ''
            ThresholdMs = [Math]::Max(0, $ThresholdMs)
        }
    }

    $effectivePath = if ([string]::IsNullOrWhiteSpace($Path)) {
        Join-Path ([System.IO.Path]::GetTempPath()) ("perfource-browser-profile-{0}.jsonl" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    } else {
        $Path
    }

    $parentDir = Split-Path -Path $effectivePath -Parent
    if (-not [string]::IsNullOrWhiteSpace($parentDir) -and -not (Test-Path -LiteralPath $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }
    Set-Content -LiteralPath $effectivePath -Value $null

    return [pscustomobject]@{
        Enabled     = $true
        Path        = $effectivePath
        ThresholdMs = [Math]::Max(0, $ThresholdMs)
    }
}

function Write-BrowserProfileEvent {
    param(
        [Parameter(Mandatory = $true)]$Profiler,
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][int]$DurationMs,
        [Parameter(Mandatory = $false)][hashtable]$Fields = @{}
    )

    if ($null -eq $Profiler -or -not [bool]$Profiler.Enabled) { return }
    if ($DurationMs -lt [int]$Profiler.ThresholdMs) { return }

    $payload = [ordered]@{
        Timestamp  = (Get-Date).ToString('o')
        Stage      = $Stage
        DurationMs = $DurationMs
    }
    foreach ($key in $Fields.Keys) {
        $payload[$key] = $Fields[$key]
    }

    Add-Content -LiteralPath ([string]$Profiler.Path) -Value (($payload | ConvertTo-Json -Compress -Depth 6))
}

function Invoke-BrowserProfiled {
    param(
        [Parameter(Mandatory = $true)]$Profiler,
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $false)][hashtable]$Fields = @{},
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock
    )

    if ($null -eq $Profiler -or -not [bool]$Profiler.Enabled) {
        return & $ScriptBlock
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        return & $ScriptBlock
    }
    finally {
        $stopwatch.Stop()
        Write-BrowserProfileEvent -Profiler $Profiler -Stage $Stage -DurationMs ([int]$stopwatch.ElapsedMilliseconds) -Fields $Fields
    }
}

function Get-BrowserProfileStateFields {
    param([Parameter(Mandatory = $true)]$State)

    $screenStackProp = $State.Ui.PSObject.Properties['ScreenStack']
    [object[]]$screenStack = if ($null -ne $screenStackProp -and $null -ne $screenStackProp.Value) {
        @($screenStackProp.Value)
    } else {
        @('Changelists')
    }

    $activeScreen = if ($screenStack.Count -gt 0) { [string]$screenStack[-1] } else { 'Changelists' }
    $viewModeProp = $State.Ui.PSObject.Properties['ViewMode']
    $activePaneProp = $State.Ui.PSObject.Properties['ActivePane']
    $visibleChangeIdsProp = $State.Derived.PSObject.Properties['VisibleChangeIds']

    return @{
        Screen             = $activeScreen
        ViewMode           = if ($null -ne $viewModeProp) { [string]$viewModeProp.Value } else { 'Pending' }
        ActivePane         = if ($null -ne $activePaneProp) { [string]$activePaneProp.Value } else { '' }
        VisibleChangeCount = if ($null -ne $visibleChangeIdsProp -and $null -ne $visibleChangeIdsProp.Value) { @($visibleChangeIdsProp.Value).Count } else { 0 }
    }
}

function Get-BrowserAsyncRegistryEntry {
    param([Parameter(Mandatory)][string]$RequestId)

    if (-not $script:AsyncJobRegistry.ContainsKey($RequestId)) { return $null }
    return $script:AsyncJobRegistry[$RequestId]
}

function Read-BrowserAsyncProcessEvents {
    param([Parameter(Mandatory)][string]$RequestId)

    $entry = Get-BrowserAsyncRegistryEntry -RequestId $RequestId
    if ($null -eq $entry) { return @() }
    if (($entry.PSObject.Properties.Match('ProcessEventFile')).Count -eq 0) { return @() }

    $eventFile = [string]$entry.ProcessEventFile
    if ([string]::IsNullOrWhiteSpace($eventFile) -or -not (Test-Path -LiteralPath $eventFile)) {
        return @()
    }

    [string[]]$allLines = @()
    try { $allLines = @(Get-Content -LiteralPath $eventFile -ErrorAction SilentlyContinue) } catch { return @() }
    $lastRead = if (($entry.PSObject.Properties.Match('LastEventLineRead')).Count -gt 0) { [int]$entry.LastEventLineRead } else { 0 }
    if ($allLines.Count -le $lastRead) { return @() }

    $newEvents = [System.Collections.Generic.List[object]]::new()
    for ($i = $lastRead; $i -lt $allLines.Count; $i++) {
        $line = [string]$allLines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $parsed = ConvertFrom-Json -InputObject $line -ErrorAction Stop
            $eventType = [string]$parsed.EventType
            $processId = if (($parsed.PSObject.Properties.Match('ProcessId')).Count -gt 0) { [int]$parsed.ProcessId } else { 0 }
            if ($eventType -eq 'ProcessStarted') {
                $existing = if (($entry.PSObject.Properties.Match('ActiveProcessIds')).Count -gt 0) { @($entry.ActiveProcessIds) } else { @() }
                if ($existing -notcontains $processId) {
                    $entry.ActiveProcessIds = @($existing + @($processId))
                }
            } elseif ($eventType -eq 'ProcessFinished') {
                $existing = if (($entry.PSObject.Properties.Match('ActiveProcessIds')).Count -gt 0) { @($entry.ActiveProcessIds) } else { @() }
                $entry.ActiveProcessIds = @($existing | Where-Object { [int]$_ -ne $processId })
            }
            $newEvents.Add([pscustomobject]@{
                Type      = $eventType
                RequestId = [string]$parsed.RequestId
                ProcessId = $processId
                ExitCode  = if (($parsed.PSObject.Properties.Match('ExitCode')).Count -gt 0 -and $null -ne $parsed.ExitCode) { [int]$parsed.ExitCode } else { $null }
            }) | Out-Null
        } catch { }
    }

    $entry.LastEventLineRead = $allLines.Count
    return @($newEvents.ToArray())
}

function Stop-BrowserAsyncRequest {
    param([Parameter(Mandatory)][string]$RequestId)

    $events = @(Read-BrowserAsyncProcessEvents -RequestId $RequestId)
    $entry  = Get-BrowserAsyncRegistryEntry -RequestId $RequestId
    $processIds = if ($null -ne $entry -and ($entry.PSObject.Properties.Match('ActiveProcessIds')).Count -gt 0) { @($entry.ActiveProcessIds) } else { @() }
    foreach ($processId in $processIds) {
        Stop-P4ProcessTree -ProcessId ([int]$processId)
    }
    & $script:AsyncExecutor.Cancel $RequestId
    return @($events)
}

function Get-BrowserCompletionOutcome {
    param([AllowNull()]$Completion)

    if ($null -eq $Completion) { return 'Failed' }
    if (($Completion.PSObject.Properties.Match('Outcome')).Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$Completion.Outcome)) {
        return [string]$Completion.Outcome
    }
    if (($Completion.PSObject.Properties.Match('Success')).Count -gt 0 -and [bool]$Completion.Success) {
        return 'Completed'
    }
    return 'Failed'
}

# ── Async worker scripts (M4.2) ───────────────────────────────────────────────
# Each worker accepts ($Envelope, $ModuleRoot).
# In production: $ModuleRoot is $PSScriptRoot; modules are imported in the isolated runspace.
# In tests: the synchronous test executor passes $null for $ModuleRoot; modules already loaded.
$script:AsyncWorkers = @{

    'ReloadPending' = {
        param([pscustomobject]$Envelope, [string]$ModuleRoot)
        if (![string]::IsNullOrEmpty($ModuleRoot)) {
            Import-Module (Join-Path $ModuleRoot 'p4\Models.psm1') -Force
            Import-Module (Join-Path $ModuleRoot 'p4\P4Cli.psm1')  -Force
        }
        $observed = [System.Collections.Generic.List[pscustomobject]]::new()
        $processObserver = {
            param($EventType,$ProcessId,$ExitCode)
            if (-not [string]::IsNullOrWhiteSpace([string]$Envelope.ProcessEventFile)) {
                $payload = [pscustomobject]@{ EventType=$EventType; RequestId=[string]$Envelope.RequestId; ProcessId=$ProcessId; ExitCode=$ExitCode }
                Add-Content -LiteralPath ([string]$Envelope.ProcessEventFile) -Value ($payload | ConvertTo-Json -Compress)
            }
        }
        Register-P4Observer {
            param($CommandLine,$RawLines,$ExitCode,$ErrorOutput,$StartedAt,$EndedAt,$DurationMs)
            $null = $RawLines  # positional param required by Invoke-P4; not used here
            $observed.Add([pscustomobject]@{ CommandLine=$CommandLine;ExitCode=$ExitCode;Succeeded=($ExitCode -eq 0)
                ErrorText=$ErrorOutput;StartedAt=$StartedAt;EndedAt=$EndedAt;DurationMs=$DurationMs;FormattedLines=@();OutputCount=0;SummaryLine='' })
        }
        try {
            $fresh = @(Get-P4ChangelistEntries -Max ([int]$Envelope.Max) -ProcessObserver $processObserver)
            return [pscustomobject]@{ Type='PendingChangesLoaded'; RequestId=$Envelope.RequestId
                Generation=$Envelope.Generation; AllChanges=@($fresh)
                ObservedCommands=@($observed); Success=$true; Outcome='Completed' }
        } catch {
            $outcome = if (Test-IsP4TimeoutError -Message $_.Exception.Message) { 'TimedOut' } else { 'Failed' }
            return [pscustomobject]@{ Type='AsyncCommandFailed'; RequestId=$Envelope.RequestId
                Generation=$Envelope.Generation; ErrorText=$_.Exception.Message
                ObservedCommands=@($observed); Success=$false; Outcome=$outcome }
        } finally { Unregister-P4Observer }
    }

    'ReloadSubmitted' = {
        param([pscustomobject]$Envelope, [string]$ModuleRoot)
        if (![string]::IsNullOrEmpty($ModuleRoot)) {
            Import-Module (Join-Path $ModuleRoot 'p4\Models.psm1') -Force
            Import-Module (Join-Path $ModuleRoot 'p4\P4Cli.psm1')  -Force
        }
        $observed = [System.Collections.Generic.List[pscustomobject]]::new()
        $processObserver = {
            param($EventType,$ProcessId,$ExitCode)
            if (-not [string]::IsNullOrWhiteSpace([string]$Envelope.ProcessEventFile)) {
                $payload = [pscustomobject]@{ EventType=$EventType; RequestId=[string]$Envelope.RequestId; ProcessId=$ProcessId; ExitCode=$ExitCode }
                Add-Content -LiteralPath ([string]$Envelope.ProcessEventFile) -Value ($payload | ConvertTo-Json -Compress)
            }
        }
        Register-P4Observer {
            param($CommandLine,$RawLines,$ExitCode,$ErrorOutput,$StartedAt,$EndedAt,$DurationMs)
            $null = $RawLines
            $observed.Add([pscustomobject]@{ CommandLine=$CommandLine;ExitCode=$ExitCode;Succeeded=($ExitCode -eq 0)
                ErrorText=$ErrorOutput;StartedAt=$StartedAt;EndedAt=$EndedAt;DurationMs=$DurationMs;FormattedLines=@();OutputCount=0;SummaryLine='' })
        }
        try {
            $client = [string]$Envelope.Client
            $fresh  = if ([string]::IsNullOrWhiteSpace($client)) {
                @(Get-P4SubmittedChangelistEntries -Max 50 -ProcessObserver $processObserver)
            } else {
                @(Get-P4SubmittedChangelistEntries -Max 50 -Client $client -ProcessObserver $processObserver)
            }
            $oldestId = if ($fresh.Count -gt 0) {
                [int]($fresh | ForEach-Object { [int]$_.Id } | Sort-Object | Select-Object -First 1)
            } else { $null }
            return [pscustomobject]@{ Type='SubmittedChangesLoaded'; RequestId=$Envelope.RequestId
                Generation=$Envelope.Generation; Entries=@($fresh); AppendMode=$false
                HasMore=($fresh.Count -ge 50); OldestId=$oldestId
                ObservedCommands=@($observed); Success=$true; Outcome='Completed' }
        } catch {
            $outcome = if (Test-IsP4TimeoutError -Message $_.Exception.Message) { 'TimedOut' } else { 'Failed' }
            return [pscustomobject]@{ Type='AsyncCommandFailed'; RequestId=$Envelope.RequestId
                Generation=$Envelope.Generation; ErrorText=$_.Exception.Message
                ObservedCommands=@($observed); Success=$false; Outcome=$outcome }
        } finally { Unregister-P4Observer }
    }

    'LoadMore' = {
        param([pscustomobject]$Envelope, [string]$ModuleRoot)
        if (![string]::IsNullOrEmpty($ModuleRoot)) {
            Import-Module (Join-Path $ModuleRoot 'p4\Models.psm1') -Force
            Import-Module (Join-Path $ModuleRoot 'p4\P4Cli.psm1')  -Force
        }
        $observed = [System.Collections.Generic.List[pscustomobject]]::new()
        $processObserver = {
            param($EventType,$ProcessId,$ExitCode)
            if (-not [string]::IsNullOrWhiteSpace([string]$Envelope.ProcessEventFile)) {
                $payload = [pscustomobject]@{ EventType=$EventType; RequestId=[string]$Envelope.RequestId; ProcessId=$ProcessId; ExitCode=$ExitCode }
                Add-Content -LiteralPath ([string]$Envelope.ProcessEventFile) -Value ($payload | ConvertTo-Json -Compress)
            }
        }
        Register-P4Observer {
            param($CommandLine,$RawLines,$ExitCode,$ErrorOutput,$StartedAt,$EndedAt,$DurationMs)
            $null = $RawLines
            $observed.Add([pscustomobject]@{ CommandLine=$CommandLine;ExitCode=$ExitCode;Succeeded=($ExitCode -eq 0)
                ErrorText=$ErrorOutput;StartedAt=$StartedAt;EndedAt=$EndedAt;DurationMs=$DurationMs;FormattedLines=@();OutputCount=0;SummaryLine='' })
        }
        try {
            $client       = [string]$Envelope.Client
            $beforeChange = $Envelope.BeforeChange
            $pageSize     = 50
            $newEntries   = if ($null -ne $beforeChange) {
                if ([string]::IsNullOrWhiteSpace($client)) {
                    @(Get-P4SubmittedChangelistEntries -Max $pageSize -BeforeChange $beforeChange -ProcessObserver $processObserver)
                } else {
                    @(Get-P4SubmittedChangelistEntries -Max $pageSize -BeforeChange $beforeChange -Client $client -ProcessObserver $processObserver)
                }
            } else {
                if ([string]::IsNullOrWhiteSpace($client)) {
                    @(Get-P4SubmittedChangelistEntries -Max $pageSize -ProcessObserver $processObserver)
                } else {
                    @(Get-P4SubmittedChangelistEntries -Max $pageSize -Client $client -ProcessObserver $processObserver)
                }
            }
            $oldestId = if ($newEntries.Count -gt 0) {
                [int]($newEntries | ForEach-Object { [int]$_.Id } | Sort-Object | Select-Object -First 1)
            } else { $null }
            return [pscustomobject]@{ Type='SubmittedChangesLoaded'; RequestId=$Envelope.RequestId
                Generation=$Envelope.Generation; Entries=@($newEntries); AppendMode=$true
                HasMore=($newEntries.Count -ge $pageSize); OldestId=$oldestId
                ObservedCommands=@($observed); Success=$true; Outcome='Completed' }
        } catch {
            $outcome = if (Test-IsP4TimeoutError -Message $_.Exception.Message) { 'TimedOut' } else { 'Failed' }
            return [pscustomobject]@{ Type='AsyncCommandFailed'; RequestId=$Envelope.RequestId
                Generation=$Envelope.Generation; ErrorText=$_.Exception.Message
                ObservedCommands=@($observed); Success=$false; Outcome=$outcome }
        } finally { Unregister-P4Observer }
    }

    'LoadFiles' = {
        param([pscustomobject]$Envelope, [string]$ModuleRoot)
        if (![string]::IsNullOrEmpty($ModuleRoot)) {
            Import-Module (Join-Path $ModuleRoot 'p4\Models.psm1') -Force
            Import-Module (Join-Path $ModuleRoot 'p4\P4Cli.psm1')  -Force
        }
        $observed  = [System.Collections.Generic.List[pscustomobject]]::new()
        $processObserver = {
            param($EventType,$ProcessId,$ExitCode)
            if (-not [string]::IsNullOrWhiteSpace([string]$Envelope.ProcessEventFile)) {
                $payload = [pscustomobject]@{ EventType=$EventType; RequestId=[string]$Envelope.RequestId; ProcessId=$ProcessId; ExitCode=$ExitCode }
                Add-Content -LiteralPath ([string]$Envelope.ProcessEventFile) -Value ($payload | ConvertTo-Json -Compress)
            }
        }
        Register-P4Observer {
            param($CommandLine,$RawLines,$ExitCode,$ErrorOutput,$StartedAt,$EndedAt,$DurationMs)
            $null = $RawLines
            $observed.Add([pscustomobject]@{ CommandLine=$CommandLine;ExitCode=$ExitCode;Succeeded=($ExitCode -eq 0)
                ErrorText=$ErrorOutput;StartedAt=$StartedAt;EndedAt=$EndedAt;DurationMs=$DurationMs;FormattedLines=@();OutputCount=0;SummaryLine='' })
        }
        $change     = [string]$Envelope.Change
        $sourceKind = [string]$Envelope.SourceKind
        $cacheKey   = [string]$Envelope.CacheKey
        try {
            if ($sourceKind -eq 'Opened') {
                $files = @(Get-P4OpenedFiles -Change $change -ProcessObserver $processObserver)
                return [pscustomobject]@{ Type='FilesBaseLoaded'; RequestId=$Envelope.RequestId
                    Generation=$Envelope.Generation; CacheKey=$cacheKey; SourceKind='Opened'
                    FileEntries=@($files); ObservedCommands=@($observed); Success=$true; Outcome='Completed' }
            } else {
                # Submitted: fetch describe, convert to file entries
                $describe = Get-P4Describe -Change $change -ProcessObserver $processObserver
                $files = @($describe.Files) | ForEach-Object {
                    New-P4FileEntry -DepotPath ([string]$_.DepotPath) `
                                    -Action ([string]$_.Action) `
                                    -FileType ([string]$_.Type) `
                                    -Change $change `
                                    -SourceKind 'Submitted' `
                                    -HeadRev ([int](if ($null -ne ($_.PSObject.Properties['Rev'])) { $_.Rev } else { 0 }))
                }
                return [pscustomobject]@{ Type='FilesBaseLoaded'; RequestId=$Envelope.RequestId
                    Generation=$Envelope.Generation; CacheKey=$cacheKey; SourceKind='Submitted'
                    FileEntries=@($files); ObservedCommands=@($observed); Success=$true; Outcome='Completed' }
            }
        } catch {
            $outcome = if (Test-IsP4TimeoutError -Message $_.Exception.Message) { 'TimedOut' } else { 'Failed' }
            return [pscustomobject]@{ Type='AsyncCommandFailed'; RequestId=$Envelope.RequestId
                Generation=$Envelope.Generation; ErrorText=$_.Exception.Message
                ObservedCommands=@($observed); Success=$false; Outcome=$outcome }
        } finally { Unregister-P4Observer }
    }

    'LoadFilesEnrichment' = {
        param([pscustomobject]$Envelope, [string]$ModuleRoot)
        if (![string]::IsNullOrEmpty($ModuleRoot)) {
            Import-Module (Join-Path $ModuleRoot 'p4\Models.psm1') -Force
            Import-Module (Join-Path $ModuleRoot 'p4\P4Cli.psm1')  -Force
        }
        $observed = [System.Collections.Generic.List[pscustomobject]]::new()
        $processObserver = {
            param($EventType,$ProcessId,$ExitCode)
            if (-not [string]::IsNullOrWhiteSpace([string]$Envelope.ProcessEventFile)) {
                $payload = [pscustomobject]@{ EventType=$EventType; RequestId=[string]$Envelope.RequestId; ProcessId=$ProcessId; ExitCode=$ExitCode }
                Add-Content -LiteralPath ([string]$Envelope.ProcessEventFile) -Value ($payload | ConvertTo-Json -Compress)
            }
        }
        Register-P4Observer {
            param($CommandLine,$RawLines,$ExitCode,$ErrorOutput,$StartedAt,$EndedAt,$DurationMs)
            $null = $RawLines
            $observed.Add([pscustomobject]@{ CommandLine=$CommandLine;ExitCode=$ExitCode;Succeeded=($ExitCode -eq 0)
                ErrorText=$ErrorOutput;StartedAt=$StartedAt;EndedAt=$EndedAt;DurationMs=$DurationMs;FormattedLines=@();OutputCount=0;SummaryLine='' })
        }
        $cacheKey = [string]$Envelope.CacheKey
        $baseFiles = @($Envelope.BaseFiles)
        try {
            $modifiedPaths  = Get-P4ModifiedDepotPaths -FileEntries $baseFiles -ProcessObserver $processObserver
            $enrichedFiles  = Set-P4FileEntriesContentModifiedState -FileEntries $baseFiles -ModifiedDepotPaths $modifiedPaths
            return [pscustomobject]@{ Type='FilesEnrichmentDone'; RequestId=$Envelope.RequestId
                Generation=$Envelope.Generation; CacheKey=$cacheKey
                FileEntries=@($enrichedFiles); ObservedCommands=@($observed); Success=$true; Outcome='Completed' }
        } catch {
            $outcome = if (Test-IsP4TimeoutError -Message $_.Exception.Message) { 'TimedOut' } else { 'Failed' }
            return [pscustomobject]@{ Type='FilesEnrichmentFailed'; RequestId=$Envelope.RequestId
                Generation=$Envelope.Generation; ErrorText=$_.Exception.Message
                CacheKey=$cacheKey; ObservedCommands=@($observed); Success=$false; Outcome=$outcome }
        } finally { Unregister-P4Observer }
    }

    'FetchDescribe' = {
        param([pscustomobject]$Envelope, [string]$ModuleRoot)
        if (![string]::IsNullOrEmpty($ModuleRoot)) {
            Import-Module (Join-Path $ModuleRoot 'p4\Models.psm1') -Force
            Import-Module (Join-Path $ModuleRoot 'p4\P4Cli.psm1')  -Force
        }
        $observed = [System.Collections.Generic.List[pscustomobject]]::new()
        $processObserver = {
            param($EventType,$ProcessId,$ExitCode)
            if (-not [string]::IsNullOrWhiteSpace([string]$Envelope.ProcessEventFile)) {
                $payload = [pscustomobject]@{ EventType=$EventType; RequestId=[string]$Envelope.RequestId; ProcessId=$ProcessId; ExitCode=$ExitCode }
                Add-Content -LiteralPath ([string]$Envelope.ProcessEventFile) -Value ($payload | ConvertTo-Json -Compress)
            }
        }
        Register-P4Observer {
            param($CommandLine,$RawLines,$ExitCode,$ErrorOutput,$StartedAt,$EndedAt,$DurationMs)
            $null = $RawLines
            $observed.Add([pscustomobject]@{ CommandLine=$CommandLine;ExitCode=$ExitCode;Succeeded=($ExitCode -eq 0)
                ErrorText=$ErrorOutput;StartedAt=$StartedAt;EndedAt=$EndedAt;DurationMs=$DurationMs;FormattedLines=@();OutputCount=0;SummaryLine='' })
        }
        $changeId = [string]$Envelope.ChangeId
        try {
            $describe = Get-P4Describe -Change $changeId -ProcessObserver $processObserver
            return [pscustomobject]@{ Type='DescribeLoaded'; RequestId=$Envelope.RequestId
                Generation=$Envelope.Generation; Change=$changeId; Describe=$describe
                ObservedCommands=@($observed); Success=$true; Outcome='Completed' }
        } catch {
            $outcome = if (Test-IsP4TimeoutError -Message $_.Exception.Message) { 'TimedOut' } else { 'Failed' }
            return [pscustomobject]@{ Type='AsyncCommandFailed'; RequestId=$Envelope.RequestId
                Generation=$Envelope.Generation; ErrorText=$_.Exception.Message
                ObservedCommands=@($observed); Success=$false; Outcome=$outcome }
        } finally { Unregister-P4Observer }
    }

    'DeleteChange' = {
        param([pscustomobject]$Envelope, [string]$ModuleRoot)
        if (![string]::IsNullOrEmpty($ModuleRoot)) {
            Import-Module (Join-Path $ModuleRoot 'p4\Models.psm1') -Force
            Import-Module (Join-Path $ModuleRoot 'p4\P4Cli.psm1')  -Force
        }
        $observed = [System.Collections.Generic.List[pscustomobject]]::new()
        $processObserver = {
            param($EventType,$ProcessId,$ExitCode)
            if (-not [string]::IsNullOrWhiteSpace([string]$Envelope.ProcessEventFile)) {
                $payload = [pscustomobject]@{ EventType=$EventType; RequestId=[string]$Envelope.RequestId; ProcessId=$ProcessId; ExitCode=$ExitCode }
                Add-Content -LiteralPath ([string]$Envelope.ProcessEventFile) -Value ($payload | ConvertTo-Json -Compress)
            }
        }
        Register-P4Observer {
            param($CommandLine,$RawLines,$ExitCode,$ErrorOutput,$StartedAt,$EndedAt,$DurationMs)
            $null = $RawLines
            $observed.Add([pscustomobject]@{ CommandLine=$CommandLine;ExitCode=$ExitCode;Succeeded=($ExitCode -eq 0)
                ErrorText=$ErrorOutput;StartedAt=$StartedAt;EndedAt=$EndedAt;DurationMs=$DurationMs;FormattedLines=@();OutputCount=0;SummaryLine='' })
        }
        try {
            Remove-P4Changelist -Change ([string]$Envelope.ChangeId) -ProcessObserver $processObserver
            return [pscustomobject]@{ Type='MutationCompleted'; RequestId=$Envelope.RequestId; Generation=$Envelope.Generation
                MutationKind='DeleteChange'; ChangeId=[string]$Envelope.ChangeId; ObservedCommands=@($observed); Success=$true; Outcome='Completed' }
        } catch {
            $outcome = if (Test-IsP4TimeoutError -Message $_.Exception.Message) { 'TimedOut' } else { 'Failed' }
            return [pscustomobject]@{ Type='AsyncCommandFailed'; RequestId=$Envelope.RequestId; Generation=$Envelope.Generation
                MutationKind='DeleteChange'; ChangeId=[string]$Envelope.ChangeId; ErrorText=$_.Exception.Message; ObservedCommands=@($observed); Success=$false; Outcome=$outcome }
        } finally { Unregister-P4Observer }
    }

    'DeleteShelvedFiles' = {
        param([pscustomobject]$Envelope, [string]$ModuleRoot)
        if (![string]::IsNullOrEmpty($ModuleRoot)) {
            Import-Module (Join-Path $ModuleRoot 'p4\Models.psm1') -Force
            Import-Module (Join-Path $ModuleRoot 'p4\P4Cli.psm1')  -Force
        }
        $observed = [System.Collections.Generic.List[pscustomobject]]::new()
        $processObserver = {
            param($EventType,$ProcessId,$ExitCode)
            if (-not [string]::IsNullOrWhiteSpace([string]$Envelope.ProcessEventFile)) {
                $payload = [pscustomobject]@{ EventType=$EventType; RequestId=[string]$Envelope.RequestId; ProcessId=$ProcessId; ExitCode=$ExitCode }
                Add-Content -LiteralPath ([string]$Envelope.ProcessEventFile) -Value ($payload | ConvertTo-Json -Compress)
            }
        }
        Register-P4Observer {
            param($CommandLine,$RawLines,$ExitCode,$ErrorOutput,$StartedAt,$EndedAt,$DurationMs)
            $null = $RawLines
            $observed.Add([pscustomobject]@{ CommandLine=$CommandLine;ExitCode=$ExitCode;Succeeded=($ExitCode -eq 0)
                ErrorText=$ErrorOutput;StartedAt=$StartedAt;EndedAt=$EndedAt;DurationMs=$DurationMs;FormattedLines=@();OutputCount=0;SummaryLine='' })
        }
        try {
            Remove-P4ShelvedFiles -Change ([string]$Envelope.ChangeId) -ProcessObserver $processObserver
            return [pscustomobject]@{ Type='MutationCompleted'; RequestId=$Envelope.RequestId; Generation=$Envelope.Generation
                MutationKind='DeleteShelvedFiles'; ChangeId=[string]$Envelope.ChangeId; ObservedCommands=@($observed); Success=$true; Outcome='Completed' }
        } catch {
            $outcome = if (Test-IsP4TimeoutError -Message $_.Exception.Message) { 'TimedOut' } else { 'Failed' }
            return [pscustomobject]@{ Type='AsyncCommandFailed'; RequestId=$Envelope.RequestId; Generation=$Envelope.Generation
                MutationKind='DeleteShelvedFiles'; ChangeId=[string]$Envelope.ChangeId; ErrorText=$_.Exception.Message; ObservedCommands=@($observed); Success=$false; Outcome=$outcome }
        } finally { Unregister-P4Observer }
    }

    'ShelveFiles' = {
        param([pscustomobject]$Envelope, [string]$ModuleRoot)
        if (![string]::IsNullOrEmpty($ModuleRoot)) {
            Import-Module (Join-Path $ModuleRoot 'p4\Models.psm1') -Force
            Import-Module (Join-Path $ModuleRoot 'p4\P4Cli.psm1')  -Force
        }
        $observed = [System.Collections.Generic.List[pscustomobject]]::new()
        $processObserver = {
            param($EventType,$ProcessId,$ExitCode)
            if (-not [string]::IsNullOrWhiteSpace([string]$Envelope.ProcessEventFile)) {
                $payload = [pscustomobject]@{ EventType=$EventType; RequestId=[string]$Envelope.RequestId; ProcessId=$ProcessId; ExitCode=$ExitCode }
                Add-Content -LiteralPath ([string]$Envelope.ProcessEventFile) -Value ($payload | ConvertTo-Json -Compress)
            }
        }
        Register-P4Observer {
            param($CommandLine,$RawLines,$ExitCode,$ErrorOutput,$StartedAt,$EndedAt,$DurationMs)
            $null = $RawLines
            $observed.Add([pscustomobject]@{ CommandLine=$CommandLine;ExitCode=$ExitCode;Succeeded=($ExitCode -eq 0)
                ErrorText=$ErrorOutput;StartedAt=$StartedAt;EndedAt=$EndedAt;DurationMs=$DurationMs;FormattedLines=@();OutputCount=0;SummaryLine='' })
        }
        try {
            Invoke-P4ShelveFiles -Change ([string]$Envelope.ChangeId) -ProcessObserver $processObserver
            return [pscustomobject]@{ Type='MutationCompleted'; RequestId=$Envelope.RequestId; Generation=$Envelope.Generation
                MutationKind='ShelveFiles'; ChangeId=[string]$Envelope.ChangeId; ObservedCommands=@($observed); Success=$true; Outcome='Completed' }
        } catch {
            $outcome = if (Test-IsP4TimeoutError -Message $_.Exception.Message) { 'TimedOut' } else { 'Failed' }
            return [pscustomobject]@{ Type='AsyncCommandFailed'; RequestId=$Envelope.RequestId; Generation=$Envelope.Generation
                MutationKind='ShelveFiles'; ChangeId=[string]$Envelope.ChangeId; ErrorText=$_.Exception.Message; ObservedCommands=@($observed); Success=$false; Outcome=$outcome }
        } finally { Unregister-P4Observer }
    }

    'SubmitChange' = {
        param([pscustomobject]$Envelope, [string]$ModuleRoot)
        if (![string]::IsNullOrEmpty($ModuleRoot)) {
            Import-Module (Join-Path $ModuleRoot 'p4\Models.psm1') -Force
            Import-Module (Join-Path $ModuleRoot 'p4\P4Cli.psm1')  -Force
        }
        $observed = [System.Collections.Generic.List[pscustomobject]]::new()
        $processObserver = {
            param($EventType,$ProcessId,$ExitCode)
            if (-not [string]::IsNullOrWhiteSpace([string]$Envelope.ProcessEventFile)) {
                $payload = [pscustomobject]@{ EventType=$EventType; RequestId=[string]$Envelope.RequestId; ProcessId=$ProcessId; ExitCode=$ExitCode }
                Add-Content -LiteralPath ([string]$Envelope.ProcessEventFile) -Value ($payload | ConvertTo-Json -Compress)
            }
        }
        Register-P4Observer {
            param($CommandLine,$RawLines,$ExitCode,$ErrorOutput,$StartedAt,$EndedAt,$DurationMs)
            $null = $RawLines
            $observed.Add([pscustomobject]@{ CommandLine=$CommandLine;ExitCode=$ExitCode;Succeeded=($ExitCode -eq 0)
                ErrorText=$ErrorOutput;StartedAt=$StartedAt;EndedAt=$EndedAt;DurationMs=$DurationMs;FormattedLines=@();OutputCount=0;SummaryLine='' })
        }
        try {
            Invoke-P4Submit -Change ([string]$Envelope.ChangeId) -ProcessObserver $processObserver
            return [pscustomobject]@{ Type='MutationCompleted'; RequestId=$Envelope.RequestId; Generation=$Envelope.Generation
                MutationKind='SubmitChange'; ChangeId=[string]$Envelope.ChangeId; ObservedCommands=@($observed); Success=$true; Outcome='Completed' }
        } catch {
            $outcome = if (Test-IsP4TimeoutError -Message $_.Exception.Message) { 'TimedOut' } else { 'Failed' }
            return [pscustomobject]@{ Type='AsyncCommandFailed'; RequestId=$Envelope.RequestId; Generation=$Envelope.Generation
                MutationKind='SubmitChange'; ChangeId=[string]$Envelope.ChangeId; ErrorText=$_.Exception.Message; ObservedCommands=@($observed); Success=$false; Outcome=$outcome }
        } finally { Unregister-P4Observer }
    }

    'MoveFiles' = {
        param([pscustomobject]$Envelope, [string]$ModuleRoot)
        if (![string]::IsNullOrEmpty($ModuleRoot)) {
            Import-Module (Join-Path $ModuleRoot 'p4\Models.psm1') -Force
            Import-Module (Join-Path $ModuleRoot 'p4\P4Cli.psm1')  -Force
        }
        $observed = [System.Collections.Generic.List[pscustomobject]]::new()
        $processObserver = {
            param($EventType,$ProcessId,$ExitCode)
            if (-not [string]::IsNullOrWhiteSpace([string]$Envelope.ProcessEventFile)) {
                $payload = [pscustomobject]@{ EventType=$EventType; RequestId=[string]$Envelope.RequestId; ProcessId=$ProcessId; ExitCode=$ExitCode }
                Add-Content -LiteralPath ([string]$Envelope.ProcessEventFile) -Value ($payload | ConvertTo-Json -Compress)
            }
        }
        Register-P4Observer {
            param($CommandLine,$RawLines,$ExitCode,$ErrorOutput,$StartedAt,$EndedAt,$DurationMs)
            $null = $RawLines
            $observed.Add([pscustomobject]@{ CommandLine=$CommandLine;ExitCode=$ExitCode;Succeeded=($ExitCode -eq 0)
                ErrorText=$ErrorOutput;StartedAt=$StartedAt;EndedAt=$EndedAt;DurationMs=$DurationMs;FormattedLines=@();OutputCount=0;SummaryLine='' })
        }
        try {
            Invoke-P4ReopenFiles -SourceChange ([string]$Envelope.ChangeId) -TargetChange ([string]$Envelope.TargetChangeId) -ProcessObserver $processObserver | Out-Null
            return [pscustomobject]@{ Type='MutationCompleted'; RequestId=$Envelope.RequestId; Generation=$Envelope.Generation
                MutationKind='MoveFiles'; ChangeId=[string]$Envelope.ChangeId; TargetChangeId=[string]$Envelope.TargetChangeId; ObservedCommands=@($observed); Success=$true; Outcome='Completed' }
        } catch {
            $outcome = if (Test-IsP4TimeoutError -Message $_.Exception.Message) { 'TimedOut' } else { 'Failed' }
            return [pscustomobject]@{ Type='AsyncCommandFailed'; RequestId=$Envelope.RequestId; Generation=$Envelope.Generation
                MutationKind='MoveFiles'; ChangeId=[string]$Envelope.ChangeId; TargetChangeId=[string]$Envelope.TargetChangeId; ErrorText=$_.Exception.Message; ObservedCommands=@($observed); Success=$false; Outcome=$outcome }
        } finally { Unregister-P4Observer }
    }

    'ResolveFile' = {
        param([pscustomobject]$Envelope, [string]$ModuleRoot)
        if (![string]::IsNullOrEmpty($ModuleRoot)) {
            Import-Module (Join-Path $ModuleRoot 'p4\Models.psm1') -Force
            Import-Module (Join-Path $ModuleRoot 'p4\P4Cli.psm1')  -Force
        }
        $observed = [System.Collections.Generic.List[pscustomobject]]::new()
        $processObserver = {
            param($EventType,$ProcessId,$ExitCode)
            if (-not [string]::IsNullOrWhiteSpace([string]$Envelope.ProcessEventFile)) {
                $payload = [pscustomobject]@{ EventType=$EventType; RequestId=[string]$Envelope.RequestId; ProcessId=$ProcessId; ExitCode=$ExitCode }
                Add-Content -LiteralPath ([string]$Envelope.ProcessEventFile) -Value ($payload | ConvertTo-Json -Compress)
            }
        }
        Register-P4Observer {
            param($CommandLine,$RawLines,$ExitCode,$ErrorOutput,$StartedAt,$EndedAt,$DurationMs)
            $null = $RawLines
            $observed.Add([pscustomobject]@{ CommandLine=$CommandLine;ExitCode=$ExitCode;Succeeded=($ExitCode -eq 0)
                ErrorText=$ErrorOutput;StartedAt=$StartedAt;EndedAt=$EndedAt;DurationMs=$DurationMs;FormattedLines=@();OutputCount=0;SummaryLine='' })
        }
        try {
            # Validate merge tool is configured and its executable exists on disk.
            $mergeTool = Get-P4MergeTool
            if (-not $mergeTool.IsSet) {
                throw 'No merge tool configured. Use Shift+R to select one.'
            }
            if (-not [string]::IsNullOrWhiteSpace($mergeTool.Path) -and -not (Test-Path -LiteralPath $mergeTool.Path)) {
                throw "Merge tool not found: '$($mergeTool.Path)'. Use Shift+R to reconfigure."
            }
            Invoke-P4Resolve -DepotPath ([string]$Envelope.DepotPath) -ProcessObserver $processObserver
            return [pscustomobject]@{ Type='MutationCompleted'; RequestId=$Envelope.RequestId; Generation=$Envelope.Generation
                MutationKind='ResolveFile'; DepotPath=[string]$Envelope.DepotPath; ObservedCommands=@($observed); Success=$true; Outcome='Completed' }
        } catch {
            $outcome = if (Test-IsP4TimeoutError -Message $_.Exception.Message) { 'TimedOut' } else { 'Failed' }
            return [pscustomobject]@{ Type='AsyncCommandFailed'; RequestId=$Envelope.RequestId; Generation=$Envelope.Generation
                MutationKind='ResolveFile'; DepotPath=[string]$Envelope.DepotPath; ErrorText=$_.Exception.Message; ObservedCommands=@($observed); Success=$false; Outcome=$outcome }
        } finally { Unregister-P4Observer }
    }

    'LoadFileLog' = {
        param([pscustomobject]$Envelope, [string]$ModuleRoot)
        if (![string]::IsNullOrEmpty($ModuleRoot)) {
            Import-Module (Join-Path $ModuleRoot 'p4\Models.psm1') -Force
            Import-Module (Join-Path $ModuleRoot 'p4\P4Cli.psm1')  -Force
        }
        $observed = [System.Collections.Generic.List[pscustomobject]]::new()
        $processObserver = {
            param($EventType,$ProcessId,$ExitCode)
            if (-not [string]::IsNullOrWhiteSpace([string]$Envelope.ProcessEventFile)) {
                $payload = [pscustomobject]@{ EventType=$EventType; RequestId=[string]$Envelope.RequestId; ProcessId=$ProcessId; ExitCode=$ExitCode }
                Add-Content -LiteralPath ([string]$Envelope.ProcessEventFile) -Value ($payload | ConvertTo-Json -Compress)
            }
        }
        Register-P4Observer {
            param($CommandLine,$RawLines,$ExitCode,$ErrorOutput,$StartedAt,$EndedAt,$DurationMs)
            $null = $RawLines
            $observed.Add([pscustomobject]@{ CommandLine=$CommandLine;ExitCode=$ExitCode;Succeeded=($ExitCode -eq 0)
                ErrorText=$ErrorOutput;StartedAt=$StartedAt;EndedAt=$EndedAt;DurationMs=$DurationMs;FormattedLines=@();OutputCount=0;SummaryLine='' })
        }
        try {
            $depotFile = [string]$Envelope.DepotFile
            $limit     = [int]$Envelope.Limit
            $laneIndex = [int]$Envelope.LaneIndex
            $revisions = @(Get-P4FileLog -DepotFile $depotFile -Limit $limit -ProcessObserver $processObserver)
            $hasMore   = $revisions.Count -ge $limit
            return [pscustomobject]@{ Type='RevisionLogLoaded'; RequestId=$Envelope.RequestId
                Generation=$Envelope.Generation; DepotFile=$depotFile; LaneIndex=$laneIndex
                Revisions=@($revisions); HasMore=$hasMore
                ObservedCommands=@($observed); Success=$true; Outcome='Completed' }
        } catch {
            $outcome = if (Test-IsP4TimeoutError -Message $_.Exception.Message) { 'TimedOut' } else { 'Failed' }
            return [pscustomobject]@{ Type='AsyncCommandFailed'; RequestId=$Envelope.RequestId
                Generation=$Envelope.Generation; ErrorText=$_.Exception.Message
                ObservedCommands=@($observed); Success=$false; Outcome=$outcome }
        } finally { Unregister-P4Observer }
    }
}

# Derives a user-visible command-line label for the modal from an async request envelope.
function Get-AsyncDisplayCommandLine {
    param([Parameter(Mandatory)][pscustomobject]$Envelope)
    switch ($Envelope.Kind) {
        'ReloadPending'       { return "p4 changes -s pending -m $([int]$Envelope.Max)" }
        'ReloadSubmitted'     {
            $spec = if ([string]::IsNullOrWhiteSpace([string]$Envelope.Client)) { '//...' } else { "//$($Envelope.Client)/..." }
            return "p4 changes -s submitted -m 50 $spec"
        }
        'LoadMore'            {
            $spec = if ([string]::IsNullOrWhiteSpace([string]$Envelope.Client)) { '//...' } else { "//$($Envelope.Client)/..." }
            return "p4 changes -s submitted -m 50 $spec"
        }
        'LoadFiles'           {
            if ([string]$Envelope.SourceKind -eq 'Opened') {
                return Format-P4CommandLine -P4Args @('fstat','-Ro','-e',[string]$Envelope.Change,'-T','change,depotFile,action,type,unresolved,haveRev,headRev','//...')
            } else {
                return Format-P4CommandLine -P4Args @('describe','-s',[string]$Envelope.Change)
            }
        }
        'LoadFilesEnrichment' { return Format-P4CommandLine -P4Args @('diff','-sa') }
        'FetchDescribe'       { return Format-P4CommandLine -P4Args @('describe','-s',[string]$Envelope.ChangeId) }
        'DeleteChange'        { return Format-P4CommandLine -P4Args @('change','-d',[string]$Envelope.ChangeId) }
        'DeleteShelvedFiles'  { return Format-P4CommandLine -P4Args @('shelve','-d','-c',[string]$Envelope.ChangeId) }
        'ShelveFiles'         { return Format-P4CommandLine -P4Args @('shelve','-f','-c',[string]$Envelope.ChangeId) }
        'SubmitChange'        { return Format-P4CommandLine -P4Args @('submit','-c',[string]$Envelope.ChangeId) }
        'MoveFiles'           { return Format-P4CommandLine -P4Args @('reopen','-c',[string]$Envelope.TargetChangeId,'//...') }
        'ResolveFile'         { return Format-P4CommandLine -P4Args @('resolve',[string]$Envelope.DepotPath) }
        'LoadFileLog'         { return Format-P4CommandLine -P4Args @('filelog','-l','-m','30',[string]$Envelope.DepotFile) }
        default               { return $Envelope.Kind }
    }
}

# Starts an async background worker for a read-only PendingRequest kind (M4.2).
# Cancels any same-scope in-flight request before starting the new one (M4.8).
# Dispatches AsyncCommandStarted to update ModalPrompt + ActiveCommand, returns updated state.
function Invoke-BrowserStartAsyncRequest {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$Request
    )

    # Build enriched envelope: carry any state-derived fields the worker needs
    $extras = @{}
    switch ($Request.Kind) {
        'ReloadPending'       { $extras['Max'] = $State.Runtime.ConfiguredMax }
        'ReloadSubmitted'     { $extras['Client'] = [string]$State.Data.CurrentClient; $extras['Max'] = 50 }
        'LoadMore'            { $extras['Client'] = [string]$State.Data.CurrentClient
                                $extras['BeforeChange'] = $State.Data.SubmittedOldestId }
        'LoadFiles'           {
            $extras['Change']     = [string]$State.Data.FilesSourceChange
            $extras['SourceKind'] = [string]$State.Data.FilesSourceKind
            $extras['CacheKey']   = [string]$Request.CacheKey
        }
        'LoadFilesEnrichment' {
            $cacheKey = [string]$Request.CacheKey
            $extras['CacheKey']  = $cacheKey
            # Pass base files so the enrichment worker has them without shared-state access
            $extras['BaseFiles'] = if ($State.Data.FileCache.ContainsKey($cacheKey)) { @($State.Data.FileCache[$cacheKey]) } else { @() }
        }
        'FetchDescribe'       { $extras['ChangeId'] = [string]$Request.ChangeId }
        'DeleteChange'        { $extras['ChangeId'] = [string]$Request.ChangeId }
        'DeleteShelvedFiles'  { $extras['ChangeId'] = [string]$Request.ChangeId }
        'ShelveFiles'         { $extras['ChangeId'] = [string]$Request.ChangeId }
        'SubmitChange'        { $extras['ChangeId'] = [string]$Request.ChangeId }
        'MoveFiles'           { $extras['ChangeId'] = [string]$Request.ChangeId; $extras['TargetChangeId'] = [string]$Request.TargetChangeId }
        'ResolveFile'         { $extras['DepotPath'] = [string]$Request.DepotPath; $extras['Change'] = [string]$Request.Change }
        'LoadFileLog'         {
            $extras['DepotFile'] = if (($Request.PSObject.Properties.Match('DepotFile')).Count -gt 0) { [string]$Request.DepotFile } else { '' }
            $extras['LaneIndex'] = if (($Request.PSObject.Properties.Match('LaneIndex')).Count -gt 0) { [int]$Request.LaneIndex } else { 0 }
            $extras['Limit']     = 30
        }
    }
    $envProps = @{}
    foreach ($p in $Request.PSObject.Properties) { $envProps[$p.Name] = $p.Value }
    foreach ($k in $extras.Keys) { $envProps[$k] = $extras[$k] }
    $envelope = [pscustomobject]$envProps

    # M4.8: cancel any in-flight request (same or different scope — single lane)
    if ($null -ne $State.Runtime.ActiveCommand) {
        Stop-BrowserAsyncRequest -RequestId ([string]$State.Runtime.ActiveCommand.RequestId) | Out-Null
    }

    # Start the worker
    $worker = $script:AsyncWorkers[$Request.Kind]
    & $script:AsyncExecutor.Execute $envelope $worker

    $displayCmd = Get-AsyncDisplayCommandLine -Envelope $envelope
    $timeoutMs  = Get-P4CommandTimeout -CommandLine $displayCmd

    return Invoke-BrowserReducer -State $State -Action ([pscustomobject]@{
        Type        = 'AsyncCommandStarted'
        RequestId   = [string]$envelope.RequestId
        Kind        = [string]$envelope.Kind
        Scope       = [string]$envelope.Scope
        Generation  = [int]$envelope.Generation
        CommandLine = $displayCmd
        TimeoutMs   = $timeoutMs
        StartedAt   = (Get-Date)
    })
}

# Polls the executor for the active async command's completion.
# Returns the typed completion payload if done, $null if still running.
function Invoke-BrowserCompletionDrain {
    param([Parameter(Mandatory = $true)]$State)
    $activeCmd = $State.Runtime.ActiveCommand
    if ($null -eq $activeCmd) { return $null }
    $requestId = [string]$activeCmd.RequestId
    $processEvents = @(Read-BrowserAsyncProcessEvents -RequestId $requestId)
    $completion = & $script:AsyncExecutor.Poll $requestId
    if ($null -eq $completion -and $processEvents.Count -eq 0) { return $null }
    return [pscustomobject]@{
        ProcessEvents = $processEvents
        Completion    = $completion
    }
}

function Invoke-BrowserCancelActiveCommand {
    param([Parameter(Mandatory = $true)]$State)

    $activeCmd = $State.Runtime.ActiveCommand
    if ($null -eq $activeCmd) { return $null }

    $requestId = [string]$activeCmd.RequestId
    $processEvents = @(Stop-BrowserAsyncRequest -RequestId $requestId)
    return [pscustomobject]@{
        ProcessEvents = $processEvents
        Completion    = [pscustomobject]@{
            Type       = 'CommandCancelled'
            RequestId  = $requestId
            Generation = [int]$activeCmd.Generation
            ErrorText  = 'Command cancelled.'
            ObservedCommands = @()
            Success    = $false
            Outcome    = 'Cancelled'
        }
    }
}

function Start-BrowserAsyncWorkflow {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$Request
    )

    $workflowKind = [string]$Request.WorkflowKind
    [string[]]$changeIds = foreach ($changeId in @($Request.ChangeIds)) {
        $text = [string]$changeId
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            $text
        }
    }
    $state = Invoke-BrowserReducer -State $State -Action ([pscustomobject]@{
        Type = 'WorkflowBegin'; Kind = $workflowKind; TotalCount = $changeIds.Count
    })

    $script:AsyncWorkflowContext = [pscustomobject]@{
        WorkflowKind   = $workflowKind
        RemainingIds   = @($changeIds)
        SuccessfulIds  = [System.Collections.Generic.List[string]]::new()
        FailedIds      = [System.Collections.Generic.List[string]]::new()
        TargetChangeId = if (($Request.PSObject.Properties.Match('TargetChangeId')).Count -gt 0) { [string]$Request.TargetChangeId } else { '' }
        LastFailureError = ''
        CurrentItemId    = ''
    }

    return Start-BrowserAsyncWorkflowNextItem -State $state
}

function Start-BrowserAsyncWorkflowNextItem {
    param([Parameter(Mandatory = $true)]$State)

    if ($null -eq $script:AsyncWorkflowContext) { return $State }

    while ($script:AsyncWorkflowContext.RemainingIds.Count -gt 0) {
        $itemId = [string]$script:AsyncWorkflowContext.RemainingIds[0]
        if ($script:AsyncWorkflowContext.RemainingIds.Count -gt 1) {
            $script:AsyncWorkflowContext.RemainingIds = @($script:AsyncWorkflowContext.RemainingIds[1..($script:AsyncWorkflowContext.RemainingIds.Count - 1)])
        } else {
            $script:AsyncWorkflowContext.RemainingIds = @()
        }

        $script:AsyncWorkflowContext.CurrentItemId = $itemId

        $request = switch ($script:AsyncWorkflowContext.WorkflowKind) {
            'DeleteMarked' {
                New-PendingRequest @{ Kind = 'DeleteChange'; ChangeId = $itemId }
                break
            }
            'DeleteShelvedFiles' {
                New-PendingRequest @{ Kind = 'DeleteShelvedFiles'; ChangeId = $itemId }
                break
            }
            'ShelveFiles' {
                New-PendingRequest @{ Kind = 'ShelveFiles'; ChangeId = $itemId }
                break
            }
            'MoveMarkedFiles' {
                if ($itemId -eq [string]$script:AsyncWorkflowContext.TargetChangeId) {
                    $State = Invoke-BrowserReducer -State $State -Action ([pscustomobject]@{ Type = 'WorkflowItemComplete' })
                    [void]$script:AsyncWorkflowContext.SuccessfulIds.Add($itemId)
                    continue
                }
                New-PendingRequest @{ Kind = 'MoveFiles'; ChangeId = $itemId; TargetChangeId = [string]$script:AsyncWorkflowContext.TargetChangeId }
                break
            }
            default {
                throw "Unsupported async workflow kind '$($script:AsyncWorkflowContext.WorkflowKind)'"
            }
        }

        return Invoke-BrowserStartAsyncRequest -State $State -Request $request
    }

    return Complete-BrowserAsyncWorkflow -State $State
}

function Complete-BrowserAsyncWorkflow {
    param([Parameter(Mandatory = $true)]$State)

    if ($null -eq $script:AsyncWorkflowContext) { return $State }

    $successfulIds = @($script:AsyncWorkflowContext.SuccessfulIds.ToArray())
    if ($successfulIds.Count -gt 0) {
        $State = Invoke-BrowserReducer -State $State -Action ([pscustomobject]@{ Type = 'UnmarkChanges'; ChangeIds = $successfulIds })
    }

    $lastFailureError = [string]$script:AsyncWorkflowContext.LastFailureError
    $script:AsyncWorkflowContext = $null
    $State = Invoke-BrowserReducer -State $State -Action ([pscustomobject]@{ Type = 'WorkflowEnd' })
    $State = Invoke-BrowserReducer -State $State -Action ([pscustomobject]@{ Type = 'Reload' })
    if (-not [string]::IsNullOrWhiteSpace($lastFailureError)) {
        $State.Runtime.LastError = $lastFailureError
    }
    return $State
}

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

        # Check for cancel/quit between DeleteMarked items (M3.3)
        $cancelSignal = & $script:CheckCancelCallback -State $state
        if ($cancelSignal -ne 'Continue') {
            $state.Runtime.CancelRequested = $true
            if ($cancelSignal -eq 'Quit') { $state.Runtime.QuitRequested = $true }
            break
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

        # Check for cancel/quit between MoveMarkedFiles items (M3.3)
        $cancelSignal = & $script:CheckCancelCallback -State $state
        if ($cancelSignal -ne 'Continue') {
            $state.Runtime.CancelRequested = $true
            if ($cancelSignal -eq 'Quit') { $state.Runtime.QuitRequested = $true }
            break
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

        # Check for cancel/quit between ShelveFiles items (M3.3)
        $cancelSignal = & $script:CheckCancelCallback -State $state
        if ($cancelSignal -ne 'Continue') {
            $state.Runtime.CancelRequested = $true
            if ($cancelSignal -eq 'Quit') { $state.Runtime.QuitRequested = $true }
            break
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

        # Check for cancel/quit between DeleteShelvedFiles items (M3.3)
        $cancelSignal = & $script:CheckCancelCallback -State $state
        if ($cancelSignal -ne 'Continue') {
            $state.Runtime.CancelRequested = $true
            if ($cancelSignal -eq 'Quit') { $state.Runtime.QuitRequested = $true }
            break
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
        $evtOutcome       = if ([bool]$evt.Succeeded) { 'Completed' } elseif (Test-IsP4TimeoutError -Message ([string]$evt.ErrorText)) { 'TimedOut' } else { 'Failed' }
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
    $outerOutcome       = if ($succeeded) { 'Completed' } elseif (Test-IsP4TimeoutError -Message $errorText) { 'TimedOut' } else { 'Failed' }
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
            AllChangeIds = foreach ($change in @($fresh)) {
                if ($null -eq $change) { continue }
                $id = [string]$change.Id
                if (-not [string]::IsNullOrWhiteSpace($id)) { $id }
            }
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
    .PARAMETER Profile
        When specified, writes slow-path timing events for the UI loop to a
        JSON Lines file.
    .PARAMETER ProfilePath
        Optional path for the profiling output.  When omitted, a timestamped
        file is created in the system temp directory.
    .PARAMETER ProfileThresholdMs
        Only stages taking at least this many milliseconds are written to the
        profiling log.  Defaults to 20 ms.
    .EXAMPLE
        Start-P4Browser
    .EXAMPLE
        Start-P4Browser -MaxChanges 500
    .EXAMPLE
        Start-P4Browser -IntegrityTest
    .EXAMPLE
        Start-P4Browser -Profile -ProfileThresholdMs 10
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [int]$MaxChanges = 200,

        [Parameter(Mandatory = $false)]
        [switch]$IntegrityTest,

        [Parameter(Mandatory = $false)]
        [switch]$Profile,

        [Parameter(Mandatory = $false)]
        [string]$ProfilePath = '',

        [Parameter(Mandatory = $false)]
        [int]$ProfileThresholdMs = 20
    )

    if ($IntegrityTest) {
        Enable-FrameIntegrityTest
    }

    Reset-RenderState

    $consoleSize = Get-BrowserConsoleSize
    $width  = [int]$consoleSize.Width
    $height = [int]$consoleSize.Height
    $state  = New-BrowserState -Changes @() -InitialWidth $width -InitialHeight $height
    $profiler = New-BrowserProfiler -Enabled ([bool]$Profile) -Path $ProfilePath -ThresholdMs $ProfileThresholdMs

    Set-RenderProfiler {
        param($Stage, $DurationMs, $Fields)
        Write-BrowserProfileEvent -Profiler $profiler -Stage $Stage -DurationMs ([int]$DurationMs) -Fields $Fields
    }

    # Phase 0.2: Store configured max for consistent reload behaviour
    $state.Runtime.ConfiguredMax = $MaxChanges

    $consoleState = Initialize-BrowserConsole

    try {
        # Populate session info from p4 info so submitted queries can be scoped
        # to the current workspace mapping from the start of the session.
        $state = Invoke-BrowserProfiled -Profiler $profiler -Stage 'Startup.P4Info' -Fields @{ MaxChanges = $MaxChanges } -ScriptBlock {
            Invoke-BrowserSideEffect -State $state -CommandLine 'p4 info' -WorkItem {
                param($s)
                $p4Info = Get-P4Info
                $s.Data.CurrentUser   = $p4Info.User
                $s.Data.CurrentClient = $p4Info.Client
                return $s
            }
        }

        # Initial load
        $loadCmdLine = "p4 changes -s pending -m $MaxChanges"
        $state = Invoke-BrowserProfiled -Profiler $profiler -Stage 'Startup.InitialLoad' -Fields @{ MaxChanges = $MaxChanges } -ScriptBlock {
            Invoke-BrowserSideEffect -State $state -CommandLine $loadCmdLine -WorkItem {
                param($s)
                $fresh = Get-P4ChangelistEntries -Max $s.Runtime.ConfiguredMax
                $s.Data.AllChanges = @($fresh)
                $s.Runtime.LastError = $null
                return Update-BrowserDerivedState -State $s
            }
        }

        if ([bool]$profiler.Enabled) {
            Write-BrowserProfileEvent -Profiler $profiler -Stage 'Profiler.Enabled' -DurationMs 0 -Fields @{ Path = [string]$profiler.Path; ThresholdMs = [int]$profiler.ThresholdMs }
        }

        while ($state.Runtime.IsRunning) {
            # Deferred quit: after blocking workflow/command, honour a queued quit request (M3.1).
            # Only dispatch Quit when not busy; if still busy let the tick loop drain the completion first.
            if ([bool]$state.Runtime.QuitRequested -and -not [bool]$state.Runtime.ModalPrompt.IsBusy) {
                $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'Quit' })
                continue
            }

            Invoke-BrowserProfiled -Profiler $profiler -Stage 'Loop.Render' -Fields (Get-BrowserProfileStateFields -State $state) -ScriptBlock {
                Render-BrowserState -State $state
            } | Out-Null

            # Tick loop: wait for a keypress OR async completion, checking resize each 50 ms (M4.3).
            $keyInfo     = $null
            $drainResult = $null
            while ($null -eq $keyInfo -and $null -eq $drainResult) {
                if (Test-BrowserConsoleKeyAvailable) {
                    $keyInfo = Read-BrowserConsoleKey
                } else {
                    # Drain async completion before sleeping (M4.3)
                    $completionFields = Get-BrowserProfileStateFields -State $state
                    $completionFields['HasActiveCommand'] = ($null -ne $state.Runtime.ActiveCommand)
                    $drainResult = Invoke-BrowserProfiled -Profiler $profiler -Stage 'Loop.CompletionDrain' -Fields $completionFields -ScriptBlock {
                        Invoke-BrowserCompletionDrain -State $state
                    }
                    if ($null -ne $drainResult) { break }
                    # Check for console resize
                    $currentSize   = Get-BrowserConsoleSize
                    $currentWidth  = [int]$currentSize.Width
                    $currentHeight = [int]$currentSize.Height
                    if ($state.Ui.Layout.Width -ne $currentWidth -or $state.Ui.Layout.Height -ne $currentHeight) {
                        $state = Invoke-BrowserProfiled -Profiler $profiler -Stage 'Loop.ResizeReducer' -Fields @{ Width = $currentWidth; Height = $currentHeight } -ScriptBlock {
                            Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
                                Type   = 'Resize'
                                Width  = $currentWidth
                                Height = $currentHeight
                            })
                        }
                        Invoke-BrowserProfiled -Profiler $profiler -Stage 'Loop.ResizeRender' -Fields @{ Width = $currentWidth; Height = $currentHeight } -ScriptBlock {
                            Render-BrowserState -State $state
                        } | Out-Null
                    }
                    Start-Sleep -Milliseconds 50
                }
            }

            # ── Key action path ───────────────────────────────────────────────────────
            $action = if ($null -ne $keyInfo) {
                Invoke-BrowserProfiled -Profiler $profiler -Stage 'Loop.InputMap' -Fields @{ Key = [string]$keyInfo.Key } -ScriptBlock {
                    ConvertFrom-KeyInfoToAction -KeyInfo $keyInfo -State $state
                }
            } else { $null }
            if ($null -ne $action) {
                $actionFields = Get-BrowserProfileStateFields -State $state
                $actionFields['ActionType'] = [string]$action.Type
                $state = Invoke-BrowserProfiled -Profiler $profiler -Stage 'Loop.ActionReducer' -Fields $actionFields -ScriptBlock {
                    Invoke-BrowserReducer -State $state -Action $action
                }

                if ([bool]$state.Runtime.CancelRequested -and $null -ne $state.Runtime.ActiveCommand) {
                    $activeRequestId = [string]$state.Runtime.ActiveCommand.RequestId
                    $state = Invoke-BrowserProfiled -Profiler $profiler -Stage 'Loop.CancelReducer' -Fields @{ RequestId = $activeRequestId } -ScriptBlock {
                        Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
                            Type      = 'AsyncCommandCancelling'
                            RequestId = $activeRequestId
                        })
                    }
                    $drainResult = Invoke-BrowserProfiled -Profiler $profiler -Stage 'Loop.CancelActiveCommand' -Fields @{ RequestId = $activeRequestId } -ScriptBlock {
                        Invoke-BrowserCancelActiveCommand -State $state
                    }
                }

                # Dispatch single PendingRequest (I/O side effects live outside the reducer)
                if ($null -eq $drainResult -and $null -ne $state.Runtime.PendingRequest) {
                    $req = $state.Runtime.PendingRequest
                    $state.Runtime.PendingRequest = $null   # consume before I/O so retries never re-fire

                    $state = Invoke-BrowserProfiled -Profiler $profiler -Stage 'Loop.PendingRequestDispatch' -Fields @{
                        Kind  = [string]$req.Kind
                        Scope = if (($req.PSObject.Properties.Match('Scope')).Count -gt 0) { [string]$req.Scope } else { '' }
                    } -ScriptBlock {
                        switch ($req.Kind) {
                            'ReloadPending' {
                                # M4: run asynchronously so the UI stays responsive
                                return Invoke-BrowserStartAsyncRequest -State $state -Request $req
                            }
                            'ReloadSubmitted' {
                                return Invoke-BrowserStartAsyncRequest -State $state -Request $req
                            }
                            'LoadMore' {
                                return Invoke-BrowserStartAsyncRequest -State $state -Request $req
                            }
                            'LoadFiles' {
                                $change     = [string]$state.Data.FilesSourceChange
                                $sourceKind = [string]$state.Data.FilesSourceKind
                                $cacheKey   = "${change}:${sourceKind}"

                                if ($state.Data.FileCache.ContainsKey($cacheKey)) {
                                    # Cache hit — recompute derived state; start async enrichment if base is ready
                                    $state = Update-BrowserDerivedState -State $state
                                    $cacheStatus = if ($state.Data.FileCacheStatus.ContainsKey($cacheKey)) { [string]$state.Data.FileCacheStatus[$cacheKey] } else { 'NotLoaded' }
                                    if ($cacheStatus -eq 'BaseReady') {
                                        $enrichReq = New-PendingRequest @{ Kind = 'LoadFilesEnrichment'; CacheKey = $cacheKey } -Generation $state.Data.FilesGeneration
                                        return Invoke-BrowserStartAsyncRequest -State $state -Request $enrichReq
                                    }
                                    return $state
                                }
                                return Invoke-BrowserStartAsyncRequest -State $state -Request $req
                            }
                            'LoadFilesEnrichment' {
                                # Idempotence: skip if already loading or done (M2.4)
                                $cacheKey = [string]$req.CacheKey
                                $currentStatus = if ($state.Data.FileCacheStatus.ContainsKey($cacheKey)) { [string]$state.Data.FileCacheStatus[$cacheKey] } else { 'NotLoaded' }
                                if ($currentStatus -notin @('LoadingEnrichment', 'Ready')) {
                                    return Invoke-BrowserStartAsyncRequest -State $state -Request $req
                                }
                                return $state
                            }
                            'FetchDescribe' {
                                $change = ConvertTo-P4ChangelistId -Value $req.ChangeId
                                if ($null -ne $change -and -not $state.Data.DescribeCache.ContainsKey($change)) {
                                    return Invoke-BrowserStartAsyncRequest -State $state -Request $req
                                }
                                return $state
                            }
                            'DeleteChange' {
                                $change = ConvertTo-P4ChangelistId -Value $req.ChangeId
                                if ($null -ne $change) {
                                    return Invoke-BrowserStartAsyncRequest -State $state -Request $req
                                }
                                return $state
                            }
                            'DeleteShelvedFiles' {
                                $change = ConvertTo-P4ChangelistId -Value $req.ChangeId
                                if ($null -ne $change) {
                                    return Invoke-BrowserStartAsyncRequest -State $state -Request $req
                                }
                                return $state
                            }
                            'SubmitChange' {
                                $change = ConvertTo-P4ChangelistId -Value $req.ChangeId
                                if ($null -ne $change) {
                                    return Invoke-BrowserStartAsyncRequest -State $state -Request $req
                                }
                                return $state
                            }
                            'SetMergeTool' {
                                # Fast local-only operation: write P4MERGE via `p4 set` directly.
                                # No async worker or command modal needed.
                                try {
                                    Set-P4MergeTool -ToolPath ([string]$req.ToolPath)
                                } catch {
                                    $state.Runtime.LastError = "Failed to set merge tool: $($_.Exception.Message)"
                                }
                                return $state
                            }
                            'ResolveFile' {
                                if (-not [string]::IsNullOrEmpty([string]$req.DepotPath)) {
                                    return Invoke-BrowserStartAsyncRequest -State $state -Request $req
                                }
                                return $state
                            }
                            'LoadFileLog' {
                                if (-not [string]::IsNullOrEmpty([string]$req.DepotFile)) {
                                    return Invoke-BrowserStartAsyncRequest -State $state -Request $req
                                }
                                return $state
                            }
                            'ExecuteWorkflow' {
                                $workflowKind = if (($req.PSObject.Properties.Match('WorkflowKind')).Count -gt 0) { [string]$req.WorkflowKind } else { '' }
                                if ([string]::IsNullOrEmpty($workflowKind) -or -not $script:WorkflowRegistry.ContainsKey($workflowKind)) {
                                    throw "Unknown workflow kind: '$workflowKind'"
                                }
                                if ($workflowKind -in $script:AsyncMutationWorkflowKinds) {
                                    return Start-BrowserAsyncWorkflow -State $state -Request $req
                                }
                                $executor = $script:WorkflowRegistry[$workflowKind]
                                # Executor receives state + request, dispatches BeginWorkflow/ItemComplete/Failed/End, returns final state
                                return & $executor -State $state -Request $req
                            }
                            default {
                                throw "Unknown PendingRequest.Kind: '$($req.Kind)'"
                            }
                        }
                    }
                }

                # After dispatching an async request, immediately drain if the result
                # is already available.  This is a no-op in production (ThreadJob is
                # still running), but essential for the synchronous test executor
                # where workers complete inline before Poll is called.
                if ($null -eq $drainResult) {
                    $drainResult = Invoke-BrowserProfiled -Profiler $profiler -Stage 'Loop.ImmediateCompletionDrain' -Fields @{ HasActiveCommand = ($null -ne $state.Runtime.ActiveCommand) } -ScriptBlock {
                        Invoke-BrowserCompletionDrain -State $state
                    }
                }
            }

            # ── Async completion path (M4.3) ──────────────────────────────────────────
            # Arrived during idle tick — process outside the key-action path for clarity.
            if ($null -ne $drainResult) {
                foreach ($procEvt in @($drainResult.ProcessEvents)) {
                    $state = Invoke-BrowserReducer -State $state -Action $procEvt
                }

                $completion = $drainResult.Completion
                if ($null -eq $completion) {
                    continue
                }

                # Step 1: CommandFinish — clears modal IsBusy and adds history entry.
                # Capture ActiveCommand BEFORE the typed action handler clears it.
                $activeCmd = $state.Runtime.ActiveCommand
                $outcome   = Get-BrowserCompletionOutcome -Completion $completion
                if ($null -ne $activeCmd) {
                    $endedAt      = Get-Date
                    $isSuccess    = ($outcome -eq 'Completed')
                    $errText      = if (($completion.PSObject.Properties.Match('ErrorText')).Count -gt 0) { [string]$completion.ErrorText } else { '' }
                    $durMs        = [int](($endedAt - [datetime]$activeCmd.StartedAt).TotalMilliseconds)
                    $durClass     = Get-DurationClass -DurationMs $durMs
                    $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
                        Type          = 'CommandFinish'
                        CommandLine   = [string]$activeCmd.CommandLine
                        StartedAt     = [datetime]$activeCmd.StartedAt
                        EndedAt       = $endedAt
                        ExitCode      = if ($isSuccess) { 0 } else { 1 }
                        Succeeded     = $isSuccess
                        ErrorText     = $errText
                        DurationClass = $durClass
                        Outcome       = $outcome
                    })
                }
                # Step 2: Typed data action — updates AllChanges / FileCache / DescribeCache etc.
                $state = Invoke-BrowserReducer -State $state -Action $completion
                # Step 3: LogCommandExecution for each p4 command observed in the worker
                [object[]]$observedCmds = @()
                if (($completion.PSObject.Properties.Match('ObservedCommands')).Count -gt 0 -and $null -ne $completion.ObservedCommands) {
                    $observedCmds = @($completion.ObservedCommands)
                }
                if ($observedCmds.Count -eq 0 -and $null -ne $activeCmd) {
                    $endedAt  = Get-Date
                    $durMs    = [int](($endedAt - [datetime]$activeCmd.StartedAt).TotalMilliseconds)
                    $durClass = Get-DurationClass -DurationMs $durMs
                    $observedCmds = @([pscustomobject]@{
                        CommandLine    = [string]$activeCmd.CommandLine
                        FormattedLines = @()
                        OutputCount    = 0
                        SummaryLine    = ''
                        ExitCode       = if ($outcome -eq 'Completed') { 0 } else { 1 }
                        ErrorText      = if (($completion.PSObject.Properties.Match('ErrorText')).Count -gt 0) { [string]$completion.ErrorText } else { '' }
                        Succeeded      = ($outcome -eq 'Completed')
                        StartedAt      = [datetime]$activeCmd.StartedAt
                        EndedAt        = $endedAt
                        DurationMs     = $durMs
                        DurationClass  = $durClass
                        Outcome        = $outcome
                    })
                }
                foreach ($obs in $observedCmds) {
                    $oDurClass = Get-DurationClass -DurationMs ([int]$obs.DurationMs)
                    $obsOutcome = if (($obs.PSObject.Properties.Match('Outcome')).Count -gt 0) { [string]$obs.Outcome } else { if ([bool]$obs.Succeeded) { 'Completed' } else { 'Failed' } }
                    $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
                        Type           = 'LogCommandExecution'
                        CommandLine    = [string]$obs.CommandLine
                        FormattedLines = @($obs.FormattedLines)
                        OutputCount    = [int]$obs.OutputCount
                        SummaryLine    = [string]$obs.SummaryLine
                        ExitCode       = [int]$obs.ExitCode
                        ErrorText      = [string]$obs.ErrorText
                        Succeeded      = [bool]$obs.Succeeded
                        StartedAt      = [datetime]$obs.StartedAt
                        EndedAt        = [datetime]$obs.EndedAt
                        DurationMs     = [int]$obs.DurationMs
                        DurationClass  = $oDurClass
                        Outcome        = $obsOutcome
                    })
                }

                if ($null -ne $script:AsyncWorkflowContext -and $null -ne $activeCmd -and [string]$completion.RequestId -eq [string]$activeCmd.RequestId) {
                    $currentItemId = [string]$script:AsyncWorkflowContext.CurrentItemId
                    switch ($outcome) {
                        'Completed' {
                            $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'WorkflowItemComplete' })
                            [void]$script:AsyncWorkflowContext.SuccessfulIds.Add($currentItemId)
                        }
                        'Failed' {
                            $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'WorkflowItemFailed'; ChangeId = $currentItemId })
                            [void]$script:AsyncWorkflowContext.FailedIds.Add($currentItemId)
                            $script:AsyncWorkflowContext.LastFailureError = if (($completion.PSObject.Properties.Match('ErrorText')).Count -gt 0) { [string]$completion.ErrorText } else { '' }
                        }
                        'TimedOut' {
                            $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'WorkflowItemFailed'; ChangeId = $currentItemId })
                            [void]$script:AsyncWorkflowContext.FailedIds.Add($currentItemId)
                            $script:AsyncWorkflowContext.LastFailureError = if (($completion.PSObject.Properties.Match('ErrorText')).Count -gt 0) { [string]$completion.ErrorText } else { '' }
                        }
                    }
                    $script:AsyncWorkflowContext.CurrentItemId = ''

                    if ($outcome -eq 'Cancelled' -or [bool]$state.Runtime.CancelRequested) {
                        $state = Complete-BrowserAsyncWorkflow -State $state
                    } elseif ($script:AsyncWorkflowContext.RemainingIds.Count -gt 0) {
                        $state = Start-BrowserAsyncWorkflowNextItem -State $state
                    } else {
                        $state = Complete-BrowserAsyncWorkflow -State $state
                    }

                    if ($null -eq $state.Runtime.ActiveCommand -and $null -ne $state.Runtime.PendingRequest) {
                        $followUp = $state.Runtime.PendingRequest
                        $state.Runtime.PendingRequest = $null
                        $state = Invoke-BrowserStartAsyncRequest -State $state -Request $followUp
                    }
                } else {
                    if ($completion.Type -eq 'MutationCompleted') {
                        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'Reload' })
                    }

                    # Step 4: Follow-up PendingRequest (e.g. LoadFilesEnrichment after FilesBaseLoaded)
                    if ($null -ne $state.Runtime.PendingRequest) {
                        $followUp = $state.Runtime.PendingRequest
                        $state.Runtime.PendingRequest = $null
                        $state = Invoke-BrowserStartAsyncRequest -State $state -Request $followUp
                    }
                }
            }

        }
    }
    finally {
        Set-RenderProfiler $null
        Reset-RenderState
        Restore-BrowserConsole -ConsoleState $consoleState
    }
}

Export-ModuleMember -Function Start-P4Browser, Register-WorkflowKind, Set-BrowserCheckCancelCallback, Set-BrowserAsyncExecutor
