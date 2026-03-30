Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Models.psm1') -Force -Global

# Overridable in tests via InModuleScope P4Cli { $script:P4Executable = 'cmd.exe' }
$script:P4Executable = 'p4.exe'

# Maximum number of formatted output lines to store per command invocation.
$script:CommandOutputMaxLines = 2000

# Shared file spec used for 'p4 fstat' queries that enumerate workspace files.
$script:P4FstatAllFilesSpec = '//...'

# Shared field list for opened-file 'p4 fstat' queries that also expose unresolved state.
$script:P4FstatOpenedFileFields = 'change,depotFile,action,type,unresolved,haveRev,headRev'

# Shared field lists for unresolved-file 'p4 fstat' queries.
$script:P4FstatUnresolvedCountFields = 'change,depotFile,unresolved'
$script:P4FstatUnresolvedPathFields  = 'depotFile,unresolved'

# Observer scriptblock invoked after each Invoke-P4 call.
# Signature: { param($CommandLine,$RawLines,$ExitCode,$ErrorOutput,$StartedAt,$EndedAt,$DurationMs) }
[scriptblock]$script:P4ExecutionObserver = $null

# ── Command execution policy (M1.1) ──────────────────────────────────────────
# Duration thresholds for DurationClass classification.
$script:CommandThresholds = [pscustomobject]@{
    InfoMs     = 500
    WarningMs  = 2000
    CriticalMs = 5000
}

# Default timeouts (ms) keyed by command category.
$script:P4TimeoutByCategory = @{
    Metadata  = 10000
    FileQuery = 30000
    Describe  = 15000
    Mutating  = 30000
}

# Maximum total time (ms) spent on per-CL unresolved enrichment inside Get-P4UnresolvedFileCounts.
# When exceeded, remaining changelists are skipped and their unresolved count defaults to 0.
$script:EnrichmentBudgetMs = 5000

function ConvertTo-P4ChangelistId {
    [CmdletBinding()]
    param(
        [AllowNull()]$Value
    )

    if ($null -eq $Value) { return $null }

    $changeId = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($changeId)) { return $null }

    if ($changeId -match '^(?i)default$') { return 'default' }
    if ($changeId -eq '0') { return 'default' }
    if ($changeId -match '^\d+$') { return $changeId }

    return $null
}

function New-P4ChangeCountDictionary {
    return [System.Collections.Generic.Dictionary[string,int]]::new([System.StringComparer]::OrdinalIgnoreCase)
}

function New-P4ChangeIdSet {
    return ,([System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase))
}

function Format-P4CommandLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string[]]$P4Args
    )
    $quoted = foreach ($arg in $P4Args) {
        if ($null -ne $arg -and $arg -ne '') {
            if ($arg -match '\s') { '"' + $arg + '"' } else { $arg }
        }
    }
    return 'p4 ' + ($quoted -join ' ')
}

function Format-P4OutputLine {
    <#
    .SYNOPSIS
        Converts raw p4 JSON output lines into human-readable summary strings.
    .DESCRIPTION
        Parses each raw JSON line defensively.  For recognised record shapes a
        concise summary is produced (e.g. "CL#12345  Fix build  user@ws").
        Unrecognised or unparseable records fall back to a compacted version of
        the raw line.  The result is capped at $script:CommandOutputMaxLines
        lines; records beyond the cap are counted but not formatted.
    .OUTPUTS
        PSCustomObject with:
          FormattedLines  string[]  — formatted lines (capped)
          OutputCount     int       — total record count before the cap
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$RawLines
    )

    $formatted = [System.Collections.Generic.List[string]]::new()
    $total = 0

    foreach ($line in $RawLines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $total++

        $record = $null
        try { $record = ConvertFrom-Json $line -ErrorAction Stop } catch { }

        if ($null -eq $record) {
            if ($formatted.Count -lt $script:CommandOutputMaxLines) {
                $fallback = ($line -replace '\s+', ' ').Trim()
                if ($fallback.Length -gt 120) { $fallback = $fallback.Substring(0, 117) + '...' }
                $formatted.Add($fallback)
            }
            continue
        }

        try {
            $parts = [System.Collections.Generic.List[string]]::new()

            if ($null -ne ($record.PSObject.Properties['change'])) {
                $parts.Add("CL#$($record.change)")
            }
            if ($null -ne ($record.PSObject.Properties['desc'])) {
                $desc = ([string]$record.desc -replace '\r?\n', ' ').Trim()
                if ($desc.Length -gt 60) { $desc = $desc.Substring(0, 57) + '...' }
                $parts.Add($desc)
            }
            if ($null -ne ($record.PSObject.Properties['user'])) {
                $userVal = [string]$record.user
                if ($null -ne ($record.PSObject.Properties['client'])) {
                    $parts.Add("$userVal@$($record.client)")
                } else {
                    $parts.Add($userVal)
                }
            } elseif ($null -ne ($record.PSObject.Properties['client'])) {
                $parts.Add("@$($record.client)")
            }
            if ($null -ne ($record.PSObject.Properties['depotFile'])) {
                $df = [string]$record.depotFile
                if ($null -ne ($record.PSObject.Properties['action'])) {
                    $parts.Add("[$($record.action)] $df")
                } else {
                    $parts.Add($df)
                }
            }
            if ($null -ne ($record.PSObject.Properties['serverAddress'])) {
                $parts.Add("server=$($record.serverAddress)")
            }

            if ($formatted.Count -lt $script:CommandOutputMaxLines) {
                if ($parts.Count -gt 0) {
                    $formatted.Add(($parts -join '  '))
                } else {
                    $fallback = ($line -replace '\s+', ' ').Trim()
                    if ($fallback.Length -gt 120) { $fallback = $fallback.Substring(0, 117) + '...' }
                    $formatted.Add($fallback)
                }
            }
        } catch {
            if ($formatted.Count -lt $script:CommandOutputMaxLines) {
                $fallback = ($line -replace '\s+', ' ').Trim()
                if ($fallback.Length -gt 120) { $fallback = $fallback.Substring(0, 117) + '...' }
                $formatted.Add($fallback)
            }
        }
    }

    return [pscustomobject]@{
        FormattedLines = @($formatted.ToArray())
        OutputCount    = $total
    }
}

function Register-P4Observer {
    <#
    .SYNOPSIS
        Registers a scriptblock to be called after every Invoke-P4 execution.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock]$Observer)
    $script:P4ExecutionObserver = $Observer
}

function Unregister-P4Observer {
    <#
    .SYNOPSIS
        Clears the registered P4 execution observer.
    #>
    [CmdletBinding()]
    param()
    $script:P4ExecutionObserver = $null
}

function Test-P4JsonRecordIsError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Record
    )

    if ($null -eq $Record) { return $false }

    $codeProp = $Record.PSObject.Properties['code']
    if ($null -ne $codeProp -and [string]::Equals([string]$codeProp.Value, 'error', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    $severityProp = $Record.PSObject.Properties['severity']
    if ($null -ne $severityProp) {
        $severity = 0
        if ([int]::TryParse([string]$severityProp.Value, [ref]$severity)) {
            return ($severity -ge 3)
        }
    }

    return $false
}

function Get-P4JsonRecordMessageText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Record,
        [AllowEmptyString()][string]$FallbackText = ''
    )

    if ($null -eq $Record) { return ([string]$FallbackText).Trim() }

    foreach ($propertyName in @('data', 'message', 'fmt', 'desc')) {
        $prop = $Record.PSObject.Properties[$propertyName]
        if ($null -eq $prop) { continue }

        $text = [string]$prop.Value
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            return ($text -replace '\r?\n', ' ').Trim()
        }
    }

    return ([string]$FallbackText).Trim()
}

function ConvertFrom-P4DiffRecordsToDepotPaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records
    )

    $result = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($record in $Records) {
        if ($null -eq $record) { continue }

        $depotPath = ''
        $depotFileProp = $record.PSObject.Properties['depotFile']
        if ($null -ne $depotFileProp) {
            $depotPath = [string]$depotFileProp.Value
        } else {
            $dataProp = $record.PSObject.Properties['data']
            if ($null -ne $dataProp) {
                $dataText = [string]$dataProp.Value
                if ($dataText -match '(//\S+)') {
                    $depotPath = [string]$Matches[1]
                }
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($depotPath)) {
            [void]$result.Add($depotPath.Trim())
        }
    }

    return ,$result
}

function Test-P4JsonRecordIsCommandFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$P4Args,
        [Parameter(Mandatory)][AllowNull()][object]$Record
    )

    if ($null -eq $Record -or $P4Args.Count -eq 0) { return $false }

    $dataText = Get-P4JsonRecordMessageText -Record $Record
    if ([string]::IsNullOrWhiteSpace($dataText)) { return $false }

    if ($P4Args.Count -ge 2 -and $P4Args[0] -eq 'change' -and $P4Args[1] -eq '-d') {
        return ($dataText -notmatch '(?i)^change\s+\d+\s+deleted\.\s*$')
    }

    return $false
}

function Get-P4CommandCategory {
    <#
    .SYNOPSIS
        Resolves the execution category for a p4 subcommand (M1.1).
    .DESCRIPTION
        Used to select category-aware default timeouts and duration-class thresholds.
        Recognised categories: FileQuery, Mutating, Describe, Metadata (default).
    .PARAMETER P4Args
        The p4 argument array; only $P4Args[0] (the subcommand) is examined.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$P4Args)

    if ($null -eq $P4Args -or $P4Args.Count -eq 0) { return 'Metadata' }
    $subcommand = [string]$P4Args[0]
    if ($subcommand -in @('fstat', 'opened', 'filelog', 'diff')) { return 'FileQuery' }
    if ($subcommand -in @('change', 'reopen', 'shelve', 'unshelve', 'resolve', 'submit')) { return 'Mutating' }
    if ($subcommand -eq 'describe') { return 'Describe' }
    return 'Metadata'
}

function Get-DurationClass {
    <#
    .SYNOPSIS
        Classifies a command duration as Normal, Info, Warning, or Critical (M1.1).
    .DESCRIPTION
        Compares $DurationMs against the named thresholds in $script:CommandThresholds
        and returns the highest matching class label.  Used by render and filtering
        to colour slow commands.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$DurationMs)

    if ($DurationMs -ge $script:CommandThresholds.CriticalMs) { return 'Critical' }
    if ($DurationMs -ge $script:CommandThresholds.WarningMs)  { return 'Warning'  }
    if ($DurationMs -ge $script:CommandThresholds.InfoMs)     { return 'Info'     }
    return 'Normal'
}

function Get-P4CommandTimeout {
    <#
    .SYNOPSIS
        Resolves the category-aware default timeout (ms) for a p4 command line string (M1.4).
    .DESCRIPTION
        Parses the subcommand from a human-readable command line (e.g. 'p4 fstat //...'),
        resolves category via Get-P4CommandCategory, and returns the matching timeout from
        $script:P4TimeoutByCategory.  Used by Invoke-BrowserSideEffect so the busy-modal
        footer can display an honest timeout value.
    .PARAMETER CommandLine
        A p4 command string beginning with 'p4 '.  Global flags (-ztag, -Mj, etc.) are
        skipped when extracting the subcommand.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CommandLine)

    # Strip leading 'p4 ' and find first non-option token (the subcommand).
    $cleaned     = $CommandLine -replace '^p4\s+', ''
    $subcommand  = ($cleaned -split '\s+' | Where-Object { $_ -ne '' -and -not $_.StartsWith('-') } | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($subcommand)) { $subcommand = '' }
    $category    = Get-P4CommandCategory -P4Args @($subcommand)
    return [int]$script:P4TimeoutByCategory[$category]
}

function Stop-P4ProcessTree {
    <#
    .SYNOPSIS
        Best-effort kill of a p4 child-process tree.
    #>
    [CmdletBinding()]
    param([int]$ProcessId)

    if ($ProcessId -le 0) { return }
    try { $null = & taskkill /F /T /PID $ProcessId 2>&1 } catch { }
}

function Test-IsP4TimeoutError {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Message)

    return ([string]$Message -match '(?i)\bp4 timed out after\b')
}

function Invoke-P4 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$P4Args,
        # Milliseconds to wait before killing the p4 process.
        # Use -1 (default) to auto-resolve a category-aware timeout (M1.4).
        [int]$TimeoutMs = -1,
        [int[]]$AllowedExitCodes = @(0),
        [AllowEmptyCollection()][string[]]$InputLines = @(),
        # Per-invocation observer callback (M0.2).  When provided, called instead of
        # the session-global $script:P4ExecutionObserver.  Enables safe async execution
        # where concurrent workers each carry their own observer without clobbering each other.
        # Signature: { param($CommandLine,$RawLines,$ExitCode,$ErrorOutput,$StartedAt,$EndedAt,$DurationMs) }
        [scriptblock]$Observer = $null,
        # Per-invocation process lifecycle callback (M5.2).
        # Signature: { param($EventType,$ProcessId,$ExitCode) }
        [scriptblock]$ProcessObserver = $null
    )

    # Resolve effective timeout: caller-supplied value when non-negative, otherwise
    # the category-aware default from $script:P4TimeoutByCategory (M1.4).
    $effectiveTimeoutMs = if ($TimeoutMs -ge 0) {
        $TimeoutMs
    } else {
        $category = Get-P4CommandCategory -P4Args $P4Args
        [int]$script:P4TimeoutByCategory[$category]
    }

    $globalArgs = @('-ztag', '-Mj')
    $fullArgs = @($globalArgs)
    if ($InputLines.Count -gt 0) {
        $fullArgs += @('-x', '-')
    }
    $fullArgs += $P4Args
    $commandLine = Format-P4CommandLine -P4Args $fullArgs

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $script:P4Executable
    $psi.Arguments = $commandLine.Substring(3)  # strip leading 'p4 '
    $psi.WorkingDirectory = (Get-Location).Path
    $psi.RedirectStandardInput = ($InputLines.Count -gt 0)
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi

    $startedAt = Get-Date
    if (-not $process.Start()) {
        throw 'Failed to start p4.exe'
    }

    if ($ProcessObserver) {
        try { & $ProcessObserver -EventType 'ProcessStarted' -ProcessId $process.Id -ExitCode $null } catch { }
    }

    if ($InputLines.Count -gt 0) {
        foreach ($line in $InputLines) {
            $process.StandardInput.WriteLine([string]$line)
        }
        $process.StandardInput.Close()
    }

    # Read stdout and stderr concurrently via async tasks to prevent the
    # deadlock that can occur when one pipe's buffer fills before the other
    # is drained.  WaitForExit(timeout) then gives us a hard upper bound on
    # how long a stalled p4 call can block the UI.
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    $exited = $process.WaitForExit($effectiveTimeoutMs)

    if (-not $exited) {
        # Kill the entire process tree (not just the root) so child processes
        # such as p4d helpers don't keep stdout/stderr pipe handles open.
        # Process.Kill() alone only terminates the direct process; on Windows
        # this leaves children alive and leaks pipe handles / async tasks.
        Stop-P4ProcessTree -ProcessId $process.Id
        try { if (-not $process.HasExited) { $process.Kill() } } catch { <# fallback #> }
        if ($ProcessObserver) {
            try { & $ProcessObserver -EventType 'ProcessFinished' -ProcessId $process.Id -ExitCode -1 } catch { }
        }
        # Dispose closes the redirected stream handles so ReadToEndAsync tasks
        # complete promptly instead of dangling until GC finalizes them.
        try { $process.Dispose() } catch { <# best-effort #> }
        throw "p4 timed out after ${effectiveTimeoutMs} ms. Args: $($psi.Arguments)"
    }

    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $exitCode = $process.ExitCode
    if ($ProcessObserver) {
        try { & $ProcessObserver -EventType 'ProcessFinished' -ProcessId $process.Id -ExitCode $exitCode } catch { }
    }
    $process.Dispose()

    $rawLines  = @(($stdout -split "`r?`n") | Where-Object { $_ -ne '' })
    $records   = @($rawLines | ForEach-Object { ConvertFrom-Json $_ })
    $stdoutErrorMessages = @()

    for ($i = 0; $i -lt $records.Count; $i++) {
        $record = $records[$i]
        $fallbackText = if ($i -lt $rawLines.Count) { [string]$rawLines[$i] } else { '' }
        if ((Test-P4JsonRecordIsError -Record $record) -or (Test-P4JsonRecordIsCommandFailure -P4Args $P4Args -Record $record)) {
            $stdoutErrorMessages += @(Get-P4JsonRecordMessageText -Record $record -FallbackText $fallbackText)
        }
    }

    $effectiveExitCode = if ((@($AllowedExitCodes) -contains $exitCode) -and [string]::IsNullOrWhiteSpace($stderr)) {
        0
    } else {
        $exitCode
    }
    if ($effectiveExitCode -eq 0 -and $stdoutErrorMessages.Count -gt 0) {
        $effectiveExitCode = 1
    }

    $effectiveErrorOutput = if (-not [string]::IsNullOrWhiteSpace($stderr)) {
        $stderr
    } elseif ($stdoutErrorMessages.Count -gt 0) {
        $stdoutErrorMessages -join "`n"
    } else {
        ''
    }

    $endedAt   = Get-Date
    $durationMs = [int](($endedAt - $startedAt).TotalMilliseconds)

    # Per-invocation observer (M0.2): use explicit $Observer when provided, otherwise fall back
    # to the session-global slot.  Async workers pass their own observer so concurrent callers
    # do not clobber each other.
    $effectiveObserver = if ($null -ne $Observer) { $Observer } else { $script:P4ExecutionObserver }
    if ($effectiveObserver) {
        try {
            & $effectiveObserver -CommandLine $commandLine -RawLines $rawLines `
                -ExitCode $effectiveExitCode -ErrorOutput $effectiveErrorOutput `
                -StartedAt $startedAt -EndedAt $endedAt -DurationMs $durationMs
        } catch { <# observer must not break p4 operations #> }
    }

    if ($effectiveExitCode -ne 0) {
        $messageParts = @(
            "p4 failed (exit $effectiveExitCode).",
            "Args: $($psi.Arguments)"
        )
        if ($stderr) { $messageParts += "STDERR: $stderr" }
        if ($stdoutErrorMessages.Count -gt 0) {
            $messageParts += "STDOUT: $($stdoutErrorMessages -join "`n")"
        } elseif ($stdout) {
            $messageParts += "STDOUT: $stdout"
        }

        throw ($messageParts -join "`n")
    }

    return $records
}

function Get-P4Info {
    [CmdletBinding()]
    param(
        [scriptblock]$ProcessObserver = $null
    )

    $lines = Invoke-P4 -P4Args @('info') -ProcessObserver $ProcessObserver

    $record = $lines | Select-Object -First 1

    [pscustomobject]@{
        User   = [string]$record.userName
        Client = [string]$record.clientName
        Port   = [string]$record.serverAddress
        Root   = [string]$record.clientRoot
    }
}

function Get-P4PendingChangelists {
    [CmdletBinding()]
    param(
        [int]$Max = 200,
        [scriptblock]$ProcessObserver = $null
    )

    $info = Get-P4Info -ProcessObserver $ProcessObserver
    $lines = Invoke-P4 -P4Args @(
        'changes',
        '-l',
        '-s', 'pending',
        '-u', $info.User,
        '-c', $info.Client,
        '-m', "$Max"
    ) -ProcessObserver $ProcessObserver

    $records = $lines
    $result = foreach ($record in $records) {
        if ($null -eq $record.change) { continue }
        if ($null -eq $record.time) { continue }

        $changeId = ConvertTo-P4ChangelistId -Value $record.change
        if ([string]::IsNullOrWhiteSpace($changeId)) { continue }

        $timestamp = [double]$record.time
        $time = [datetime]::UnixEpoch.AddSeconds($timestamp).ToLocalTime()

        New-P4ChangelistRecord `
            -Change $changeId `
            -User ([string]$record.user) `
            -Client ([string]$record.client) `
            -Time $time `
            -Status ([string]$record.status) `
            -Description ([string]$record.desc)
    }

    return @($result | Sort-Object Time -Descending)
}

function Get-P4ChangelistEntries {
    [CmdletBinding()]
    param(
        [int]$Max = 200,
        [scriptblock]$ProcessObserver = $null
    )

    $changelists     = @(Get-P4PendingChangelists -Max $Max -ProcessObserver $ProcessObserver)
    $openedCounts    = Get-P4OpenedFileCounts -ProcessObserver $ProcessObserver

    $hasDefaultPending = @($changelists | Where-Object { [string]$_.Change -eq 'default' }).Count -gt 0
    if ($openedCounts.ContainsKey('default') -and -not $hasDefaultPending) {
        $defaultUser = ''
        $defaultClient = ''
        if ($changelists.Count -gt 0) {
            $defaultUser = [string]$changelists[0].User
            $defaultClient = [string]$changelists[0].Client
        } else {
            $info = Get-P4Info -ProcessObserver $ProcessObserver
            $defaultUser = [string]$info.User
            $defaultClient = [string]$info.Client
        }

        $defaultChangelist = New-P4ChangelistRecord `
            -Change 'default' `
            -User $defaultUser `
            -Client $defaultClient `
            -Time (Get-Date) `
            -Status 'pending' `
            -Description 'Default changelist'

        $changelists = @($defaultChangelist) + @($changelists)
    }

    $changeNumbers   = @(
        $changelists |
            ForEach-Object { ConvertTo-P4ChangelistId -Value $_.Change } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    $shelvedCounts   = Get-P4ShelvedFileCounts -ChangeNumbers $changeNumbers -ProcessObserver $ProcessObserver

    # Workspace-wide unresolved enrichment — degrades gracefully on failure.
    # Short-circuit when there are no pending changelists to avoid unnecessary p4 fstat calls.
    $unresolvedCounts = if ($changeNumbers.Count -gt 0) {
        Get-P4UnresolvedFileCounts -ChangeNumbers $changeNumbers -ProcessObserver $ProcessObserver
    } else {
        New-P4ChangeCountDictionary
    }

    $changelists | ForEach-Object {
        $changeNum        = [string]$_.Change
        $openedCount      = if ($openedCounts.ContainsKey($changeNum))    { $openedCounts[$changeNum]    } else { 0 }
        $shelvedCount     = if ($shelvedCounts.ContainsKey($changeNum))   { $shelvedCounts[$changeNum]   } else { 0 }
        $unresolvedCount  = if ($unresolvedCounts.ContainsKey($changeNum)) { $unresolvedCounts[$changeNum] } else { 0 }
        ConvertTo-ChangelistEntry -Changelist $_ -OpenedFileCount $openedCount `
            -ShelvedFileCount $shelvedCount -UnresolvedFileCount $unresolvedCount
    }
}

function ConvertFrom-P4DescribeRecordToFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Record
    )

    $files = [System.Collections.Generic.List[object]]::new()

    $indexedDepotProps = @(
        $Record.PSObject.Properties |
            Where-Object { $_.Name -match '^depotFile(\d+)$' } |
            Sort-Object { [int]$_.Name.Substring('depotFile'.Length) }
    )

    if ($indexedDepotProps.Count -gt 0) {
        foreach ($prop in $indexedDepotProps) {
            $index     = [int]$prop.Name.Substring('depotFile'.Length)
            $actionProp = $Record.PSObject.Properties["action$index"]
            $typeProp   = $Record.PSObject.Properties["type$index"]
            $revProp    = $Record.PSObject.Properties["rev$index"]
            $files.Add([pscustomobject]@{
                DepotPath = [string]$prop.Value
                Action    = if ($null -ne $actionProp) { [string]$actionProp.Value } else { '' }
                Type      = if ($null -ne $typeProp)   { [string]$typeProp.Value }   else { '' }
                Rev       = if ($null -ne $revProp)    { [int]$revProp.Value }        else { 0  }
            }) | Out-Null
        }

        return @($files.ToArray())
    }

    if ($null -ne ($Record.PSObject.Properties['depotFile'])) {
        $depotFiles = @($Record.depotFile)
        $actions    = @(if ($null -ne ($Record.PSObject.Properties['action'])) { $Record.action })
        $types      = @(if ($null -ne ($Record.PSObject.Properties['type']))   { $Record.type   })
        $revs       = @(if ($null -ne ($Record.PSObject.Properties['rev']))    { $Record.rev    })

        for ($i = 0; $i -lt $depotFiles.Count; $i++) {
            $files.Add([pscustomobject]@{
                DepotPath = [string]$depotFiles[$i]
                Action    = if ($i -lt $actions.Count) { [string]$actions[$i] } else { '' }
                Type      = if ($i -lt $types.Count)   { [string]$types[$i]   } else { '' }
                Rev       = if ($i -lt $revs.Count)    { [int]$revs[$i] }       else { 0  }
            }) | Out-Null
        }
    }

    return @($files.ToArray())
}

function Get-P4Describe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Change,
        [scriptblock]$ProcessObserver = $null
    )

    $lines = Invoke-P4 -P4Args @('describe', '-s', "$Change") -ProcessObserver $ProcessObserver

    $record = $lines | Select-Object -First 1
    if ($null -eq $record -or $null -eq ($record.PSObject.Properties['change'])) {
        $msg = Get-P4JsonRecordMessageText -Record $record -FallbackText "Failed to parse describe output for CL $Change"
        throw $msg
    }

    $time = if ($null -ne ($record.PSObject.Properties['time'])) {
        ([datetime]'1970-01-01T00:00:00Z').AddSeconds([double]$record.time).ToLocalTime()
    } else { Get-Date }

    $files = @(ConvertFrom-P4DescribeRecordToFiles -Record $record)
    $changeId = ConvertTo-P4ChangelistId -Value $record.change
    if ([string]::IsNullOrWhiteSpace($changeId)) {
        throw "Failed to parse describe output for CL $Change"
    }

    $descLines = @([string]$record.desc -split "`r?`n" | Where-Object { $_ -ne '' })

    [pscustomobject]@{
        Change      = $changeId
        User        = [string]$record.user
        Client      = [string]$record.client
        Status      = [string]$record.status
        Time        = $time
        Description = $descLines
        Files       = @($files)
    }
}

function New-P4FstatArgs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RecursionFlag,
        [Parameter(Mandatory)][string]$Fields,
        [string]$Change
    )

    $p4Args = @('fstat', "-R$RecursionFlag")
    if ($PSBoundParameters.ContainsKey('Change') -and -not [string]::IsNullOrWhiteSpace($Change)) {
        $p4Args += @('-e', "$Change")
    }

    $p4Args += @('-T', $Fields, $script:P4FstatAllFilesSpec)
    return ,$p4Args
}

function Test-IsP4NoOpenedFilesError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message
    )

    return ($Message -match '(?i)file\(s\)\s+not\s+opened|no\s+such\s+file\(s\)')
}

function New-P4FstatOpenedArgs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Change
    )

    return New-P4FstatArgs -RecursionFlag 'o' -Fields $script:P4FstatOpenedFileFields -Change $Change
}

function Test-P4FstatRecordIsUnresolved {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Record
    )

    $unresolvedProp = $Record.PSObject.Properties['unresolved']
    if ($null -eq $unresolvedProp) { return $false }

    $unresolvedText = [string]$unresolvedProp.Value
    if ([string]::IsNullOrWhiteSpace($unresolvedText)) { return $true }

    $unresolvedCount = 0
    if ([int]::TryParse($unresolvedText, [ref]$unresolvedCount)) {
        return ($unresolvedCount -gt 0)
    }

    return $true
}

function Test-IsP4NoShelvedChangesError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message
    )

    return ($Message -match '(?i)no\s+matching\s+changelists')
}

# Pure helper: count opened files per changelist from 'p4 -ztag -Mj opened' JSON output.
# Each PSObject record corresponds to one opened file; 'change' identifies the CL.
function ConvertFrom-P4OpenedLinesToFileCounts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records
    )

    $result = New-P4ChangeCountDictionary
    foreach ($record in $Records) {
        if ($null -eq ($record.PSObject.Properties['change'])) { continue }
        $change = ConvertTo-P4ChangelistId -Value $record.change
        if ([string]::IsNullOrWhiteSpace($change)) { continue }
        if ($result.ContainsKey($change)) { $result[$change]++ } else { $result[$change] = 1 }
    }
    return $result
}

# Pure helper: count shelved files per changelist from 'p4 -ztag -Mj describe -S -s' JSON output.
# Each PSObject record is one changelist; files may be exposed either as a
# depotFile array property or as indexed depotFileN properties.
function ConvertFrom-P4DescribeShelvedLinesToFileCounts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records
    )

    $result = New-P4ChangeCountDictionary
    foreach ($record in $Records) {
        if ($null -eq ($record.PSObject.Properties['change'])) { continue }
        $change        = ConvertTo-P4ChangelistId -Value $record.change
        if ([string]::IsNullOrWhiteSpace($change)) { continue }
        $describedFiles = @(ConvertFrom-P4DescribeRecordToFiles -Record $record)
        $fileCount     = $describedFiles.Count
        $result[$change] = $fileCount
    }
    return $result
}

function Get-P4OpenedFileCounts {
    <#
    .SYNOPSIS
        Returns a dictionary mapping changelist number to the count of opened files in that CL.
    #>
    [CmdletBinding()]
    param(
        [scriptblock]$ProcessObserver = $null
    )

    try {
        $lines = Invoke-P4 -P4Args @('opened') -ProcessObserver $ProcessObserver
    }
    catch {
        $errorMessage = [string]$_.Exception.Message
        if (-not (Test-IsP4NoOpenedFilesError -Message $errorMessage)) {
            throw
        }
        # No files opened is not an error
        return New-P4ChangeCountDictionary
    }

    if ($null -eq $lines) { $lines = @() }
    return ConvertFrom-P4OpenedLinesToFileCounts -Records $lines
}

function Get-P4OpenedChangeNumbers {
    <#
    .SYNOPSIS
        Returns the set of changelist numbers that have at least one opened file.
    .DESCRIPTION
        Adapter around Get-P4OpenedFileCounts. Returns only the keys (CL numbers).
    #>
    [CmdletBinding()]
    param()

    $counts = Get-P4OpenedFileCounts
    $result = New-P4ChangeIdSet
    foreach ($key in $counts.Keys) {
        [void]$result.Add($key)
    }
    return ,$result
}

function Get-P4ShelvedChangeNumbers {
    <#
    .SYNOPSIS
        Returns the set of changelist numbers that have shelved files.
    .DESCRIPTION
        Uses 'p4 -ztag changes -s shelved -u <user> -c <client>' to efficiently
        find all CLs with shelved files in a single command.
    #>
    [CmdletBinding()]
    param()

    $info = Get-P4Info
    try {
        $lines = Invoke-P4 -P4Args @('changes', '-s', 'shelved', '-u', $info.User, '-c', $info.Client)
    }
    catch {
        $errorMessage = [string]$_.Exception.Message
        if (-not (Test-IsP4NoShelvedChangesError -Message $errorMessage)) {
            throw
        }
        return ,(New-P4ChangeIdSet)
    }

    $result = New-P4ChangeIdSet
    foreach ($record in $lines) {
        if ($null -eq ($record.PSObject.Properties['change'])) { continue }
        $changeId = ConvertTo-P4ChangelistId -Value $record.change
        if ([string]::IsNullOrWhiteSpace($changeId)) { continue }
        [void]$result.Add($changeId)
    }

    return ,$result
}

function Get-P4ShelvedFileCounts {
    <#
    .SYNOPSIS
        Returns a dictionary mapping changelist number to the count of shelved files.
    .DESCRIPTION
        Uses batched 'p4 -ztag describe -S -s' calls to count shelved files per CL.
        Change numbers are submitted in chunks to stay within command-line length limits.
        On describe failure, degrades gracefully and returns empty counts for that chunk.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ChangeNumbers,
        [scriptblock]$ProcessObserver = $null
    )

    $result = New-P4ChangeCountDictionary
    if ($null -eq $ChangeNumbers -or $ChangeNumbers.Count -eq 0) {
        return $result
    }

    $chunkSize = 50
    for ($i = 0; $i -lt $ChangeNumbers.Count; $i += $chunkSize) {
        $end   = [Math]::Min($i + $chunkSize - 1, $ChangeNumbers.Count - 1)
        $chunk = $ChangeNumbers[$i..$end]
        $p4Args = @('describe', '-S', '-s') + @($chunk | ForEach-Object { "$_" })
        try {
            $lines = Invoke-P4 -P4Args $p4Args -ProcessObserver $ProcessObserver
            if ($null -eq $lines) { $lines = @() }
            $chunkCounts = ConvertFrom-P4DescribeShelvedLinesToFileCounts -Records $lines
            foreach ($kvp in $chunkCounts.GetEnumerator()) {
                $result[$kvp.Key] = $kvp.Value
            }
        }
        catch {
            # Degrade gracefully: skip shelved counts for this chunk rather than failing the load
        }
    }

    return $result
}

function Get-P4OpenedFiles {
    <#
    .SYNOPSIS
        Returns FileEntry objects for all files opened in the given pending changelist.
    .DESCRIPTION
        Calls 'p4 -ztag -Mj fstat -Ro -e <cl> -T change,depotFile,action,type,unresolved //...'
        (global flags added by Invoke-P4) and returns parsed PSObjects as FileEntry objects.
        When present, the 'unresolved' field is projected into FileEntry.IsUnresolved.
        An empty changelist (no opened files) returns an empty array without throwing.
    .PARAMETER Change
        The changelist number whose opened files to retrieve.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Change,
        [scriptblock]$ProcessObserver = $null
    )

    $lines = @()
    try {
        $lines = @(Invoke-P4 -P4Args (New-P4FstatOpenedArgs -Change $Change) -ProcessObserver $ProcessObserver)
    }
    catch {
        $errorMessage = [string]$_.Exception.Message
        if (Test-IsP4NoOpenedFilesError -Message $errorMessage) {
            return @()
        }
        throw
    }

    if ($lines.Count -eq 0) { return @() }

    $result = foreach ($record in $lines) {
        if ($null -eq ($record.PSObject.Properties['depotFile'])) { continue }
        $depotPath = [string]$record.depotFile
        $action    = if ($null -ne ($record.PSObject.Properties['action'])) { [string]$record.action } else { '' }
        $fileType  = if ($null -ne ($record.PSObject.Properties['type']))   { [string]$record.type   } else { '' }
        $recChange = if ($null -ne ($record.PSObject.Properties['change'])) {
            ConvertTo-P4ChangelistId -Value $record.change
        } else {
            ConvertTo-P4ChangelistId -Value $Change
        }
        if ([string]::IsNullOrWhiteSpace($recChange)) { $recChange = [string]$Change }
        $isUnresolved = Test-P4FstatRecordIsUnresolved -Record $record
        $haveRev = if ($null -ne ($record.PSObject.Properties['haveRev'])) { [int]$record.haveRev } else { 0 }
        $headRev = if ($null -ne ($record.PSObject.Properties['headRev'])) { [int]$record.headRev } else { 0 }
        New-P4FileEntry -DepotPath $depotPath -Action $action -FileType $fileType `
                        -Change $recChange -SourceKind 'Opened' -IsUnresolved $isUnresolved `
                        -HaveRev $haveRev -HeadRev $headRev
    }

    return @($result)
}

function Test-IsP4NoUnresolvedFilesError {
    <#
    .SYNOPSIS
        Returns $true when the p4 error message indicates no unresolved files exist.
    .DESCRIPTION
        'p4 fstat -Ru //...' exits non-zero with a 'no such file(s)' message when
        the workspace or changelist has no unresolved open files. This should be
        treated as a normal empty result rather than an error.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message
    )

    return ($Message -match '(?i)no\s+such\s+file\(s\)')
}

function New-P4FstatUnresolvedArgs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Fields,
        [string]$Change
    )

    return New-P4FstatArgs -RecursionFlag 'u' -Fields $Fields -Change $Change
}

# Pure helper: convert 'p4 fstat -Ru' records into a per-changelist unresolved file count.
# Each record represents one unresolved open file; 'change' identifies the CL.
function ConvertFrom-P4FstatUnresolvedRecordsToFileCounts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records
    )

    $result = New-P4ChangeCountDictionary
    foreach ($record in $Records) {
        if ($null -eq ($record.PSObject.Properties['change'])) { continue }
        $changeId = ConvertTo-P4ChangelistId -Value $record.change
        if ([string]::IsNullOrWhiteSpace($changeId)) { continue }
        if ($result.ContainsKey($changeId)) { $result[$changeId]++ } else { $result[$changeId] = 1 }
    }
    return $result
}

function Get-P4UnresolvedFileCounts {
    <#
    .SYNOPSIS
        Returns a dictionary mapping changelist number to its unresolved open-file count.
    .DESCRIPTION
        When ChangeNumbers are supplied, uses changelist-scoped
        'p4 fstat -Ru -e <change> -T change,depotFile,unresolved //...'
        queries so pending changelist enrichment is explicit and valid.
        When ChangeNumbers are omitted, falls back to a workspace-wide
        'p4 fstat -Ru -T change,depotFile,unresolved //...' query.
        Returns an empty dictionary when there are no unresolved files.
        Degrades gracefully to an empty dictionary on unexpected failures so that
        pending changelist loading is never blocked by unresolved enrichment errors.
    .PARAMETER ChangeNumbers
        Optional pending changelist numbers to query individually with '-e <change>'.
    .PARAMETER BudgetMs
        Maximum total milliseconds to spend on per-CL queries (M2.5 enrichment budget).
        Pass -1 (default) to use $script:EnrichmentBudgetMs. Pass [int]::MaxValue to disable.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][string[]]$ChangeNumbers = @(),
        [int]$BudgetMs = -1,
        [scriptblock]$ProcessObserver = $null
    )

    $effectiveBudgetMs = if ($BudgetMs -ge 0) { $BudgetMs } else { $script:EnrichmentBudgetMs }

    $changesToQuery = [System.Collections.Generic.List[string]]::new()
    $seenChanges = New-P4ChangeIdSet
    foreach ($changeNumber in @($ChangeNumbers)) {
        $changeId = ConvertTo-P4ChangelistId -Value $changeNumber
        if ([string]::IsNullOrWhiteSpace($changeId)) { continue }
        if ($seenChanges.Add($changeId)) {
            [void]$changesToQuery.Add($changeId)
        }
    }

    if ($changesToQuery.Count -gt 0) {
        $result = New-P4ChangeCountDictionary
        $budgetStart = [datetime]::UtcNow

        foreach ($change in $changesToQuery) {
            # Respect enrichment time budget (M2.5): skip remaining CLs if budget exceeded.
            $elapsedMs = ([datetime]::UtcNow - $budgetStart).TotalMilliseconds
            if ($elapsedMs -gt $effectiveBudgetMs) {
                break
            }

            try {
                $lines = Invoke-P4 -P4Args (New-P4FstatUnresolvedArgs -Fields $script:P4FstatUnresolvedCountFields -Change $change) -ProcessObserver $ProcessObserver
            }
            catch {
                $errorMessage = [string]$_.Exception.Message
                if (Test-IsP4NoUnresolvedFilesError -Message $errorMessage) {
                    continue
                }

                # Degrade gracefully: skip this changelist rather than blocking changelist load.
                continue
            }

            if ($null -eq $lines) { continue }

            $recordCount = @(
                $lines |
                    Where-Object { $null -ne ($_.PSObject.Properties['depotFile']) }
            ).Count

            if ($recordCount -gt 0) {
                $result[$change] = $recordCount
            }
        }

        return $result
    }

    try {
        $lines = Invoke-P4 -P4Args (New-P4FstatUnresolvedArgs -Fields $script:P4FstatUnresolvedCountFields) -ProcessObserver $ProcessObserver
    }
    catch {
        $errorMessage = [string]$_.Exception.Message
        if (Test-IsP4NoUnresolvedFilesError -Message $errorMessage) {
            return New-P4ChangeCountDictionary
        }
        # Degrade gracefully: return empty counts rather than blocking changelist load
        return New-P4ChangeCountDictionary
    }

    if ($null -eq $lines) { $lines = @() }
    return ConvertFrom-P4FstatUnresolvedRecordsToFileCounts -Records $lines
}

function Get-P4UnresolvedDepotPaths {
    <#
    .SYNOPSIS
        Returns a case-insensitive HashSet of depot paths for unresolved files in a changelist.
    .DESCRIPTION
        Uses 'p4 fstat -Ru -e <change> -T depotFile,unresolved //...' to retrieve
        the subset of opened files that are unresolved. Returns an empty set when the
        changelist has no unresolved files.
    .PARAMETER Change
        The pending changelist number to query.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Change
    )

    $result = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    try {
        $openedFiles = @(Get-P4OpenedFiles -Change $Change)
    }
    catch {
        return ,$result
    }

    if ($null -eq $openedFiles) {
        return ,$result
    }

    foreach ($entry in $openedFiles) {
        if (-not [bool]$entry.IsUnresolved) { continue }
        [void]$result.Add([string]$entry.DepotPath)
    }

    return ,$result
}

function Test-P4FileEntrySupportsContentDiff {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$FileEntry
    )

    $action = [string]$FileEntry.Action
    if ([string]::IsNullOrWhiteSpace($action)) { return $false }

    return ($action -notmatch '(?i)(^|/)(add|delete)$')
}

function Get-P4ModifiedDepotPaths {
    <#
    .SYNOPSIS
        Returns a case-insensitive HashSet of depot paths whose workspace content differs from depot.
    .DESCRIPTION
        Uses 'p4 diff -sa' with depot paths supplied on standard input via '-x -'.
        The input file list is typically the opened-file set for a single pending changelist.
        Returns an empty set when there are no diffable files or when the diff command
        reports no modified files.
    .PARAMETER FileEntries
        Opened-file entries whose depot paths should be diffed against depot content.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$FileEntries,
        [scriptblock]$ProcessObserver = $null
    )

    $result = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($null -eq $FileEntries -or $FileEntries.Count -eq 0) {
        return ,$result
    }

    [string[]]$depotPaths = @(
        $FileEntries |
            Where-Object { Test-P4FileEntrySupportsContentDiff -FileEntry $_ } |
            ForEach-Object { [string]$_.DepotPath } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Stable -Unique
    )

    if ($depotPaths.Count -eq 0) {
        return ,$result
    }

    try {
        $lines = @(Invoke-P4 -P4Args @('diff', '-sa') -AllowedExitCodes @(0, 1) -InputLines $depotPaths -ProcessObserver $ProcessObserver)
    }
    catch {
        return ,$result
    }

    if ($null -eq $lines -or $lines.Count -eq 0) {
        return ,$result
    }

    return ConvertFrom-P4DiffRecordsToDepotPaths -Records $lines
}

function Set-P4FileEntriesUnresolvedState {
    <#
    .SYNOPSIS
        Returns new FileEntry objects with IsUnresolved set based on membership in the given set of unresolved depot paths.
    .DESCRIPTION
        Accepts an array of FileEntry objects and a case-insensitive HashSet of unresolved
        depot paths.  Returns new FileEntry objects reconstructed via New-P4FileEntry so
        each entry has a complete and stable shape.  Does not mutate the input objects.
    .PARAMETER FileEntries
        Array of FileEntry objects (as returned by Get-P4OpenedFiles).
    .PARAMETER UnresolvedDepotPaths
        Case-insensitive HashSet of depot paths that are unresolved.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$FileEntries,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]]$UnresolvedDepotPaths
    )

    if ($null -eq $UnresolvedDepotPaths) {
        $UnresolvedDepotPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    }

    $result = foreach ($entry in $FileEntries) {
        $depotPath    = [string]$entry.DepotPath
        $isUnresolved = [bool]$UnresolvedDepotPaths.Contains($depotPath)
        $haveRev      = if ($null -ne ($entry.PSObject.Properties['HaveRev'])) { [int]$entry.HaveRev } else { 0 }
        $headRev      = if ($null -ne ($entry.PSObject.Properties['HeadRev'])) { [int]$entry.HeadRev } else { 0 }
        New-P4FileEntry `
            -DepotPath    $depotPath `
            -Action       ([string]$entry.Action) `
            -FileType     ([string]$entry.FileType) `
            -Change       ([string]$entry.Change) `
            -SourceKind   ([string]$entry.SourceKind) `
            -IsUnresolved $isUnresolved `
            -HaveRev      $haveRev `
            -HeadRev      $headRev
    }

    return @($result)
}

function Set-P4FileEntriesContentModifiedState {
    <#
    .SYNOPSIS
        Returns new FileEntry objects with IsContentModified set based on membership in the given depot-path set.
    .DESCRIPTION
        Accepts an array of FileEntry objects and a case-insensitive HashSet of modified
        depot paths. Returns new FileEntry objects reconstructed via New-P4FileEntry so
        each entry has a complete and stable shape. Does not mutate the input objects.
    .PARAMETER FileEntries
        Array of FileEntry objects (as returned by Get-P4OpenedFiles).
    .PARAMETER ModifiedDepotPaths
        Case-insensitive HashSet of depot paths whose workspace content differs from depot.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$FileEntries,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]]$ModifiedDepotPaths
    )

    if ($null -eq $ModifiedDepotPaths) {
        $ModifiedDepotPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    }

    $result = foreach ($entry in $FileEntries) {
        $depotPath         = [string]$entry.DepotPath
        $isContentModified = [bool]$ModifiedDepotPaths.Contains($depotPath)
        $haveRev           = if ($null -ne ($entry.PSObject.Properties['HaveRev'])) { [int]$entry.HaveRev } else { 0 }
        $headRev           = if ($null -ne ($entry.PSObject.Properties['HeadRev'])) { [int]$entry.HeadRev } else { 0 }
        New-P4FileEntry `
            -DepotPath         $depotPath `
            -Action            ([string]$entry.Action) `
            -FileType          ([string]$entry.FileType) `
            -Change            ([string]$entry.Change) `
            -SourceKind        ([string]$entry.SourceKind) `
            -IsUnresolved      ([bool]$entry.IsUnresolved) `
            -IsContentModified $isContentModified `
            -HaveRev           $haveRev `
            -HeadRev           $headRev
    }

    return @($result)
}

function Remove-P4Changelist {
    <#
    .SYNOPSIS
        Deletes a pending changelist.
    .DESCRIPTION
        Runs 'p4 change -d <change>' to delete the specified changelist.
        The changelist must be empty (no open files, no shelved files).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Change,
        [scriptblock]$ProcessObserver = $null
    )

    Invoke-P4 -P4Args @('change', '-d', "$Change") -ProcessObserver $ProcessObserver | Out-Null
}

function Invoke-P4ShelveFiles {
    <#
    .SYNOPSIS
        Shelves all opened files in a pending changelist.
    .DESCRIPTION
        Runs 'p4 shelve -c <change>' to shelve all opened files in the specified
        pending changelist.  Existing shelved files for the changelist are
        replaced (-f flag).  The opened files remain checked-out after shelving.
    .PARAMETER Change
        The pending changelist number whose opened files should be shelved.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Change,
        [scriptblock]$ProcessObserver = $null
    )

    Invoke-P4 -P4Args @('shelve', '-f', '-c', "$Change") -ProcessObserver $ProcessObserver | Out-Null
}

function Invoke-P4Submit {
    <#
    .SYNOPSIS
        Submits a pending changelist.
    .DESCRIPTION
        Runs 'p4 submit -c <change>' to submit the specified pending changelist
        to the depot.  All opened files in the changelist are committed.
    .PARAMETER Change
        The pending changelist number to submit.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Change,
        [scriptblock]$ProcessObserver = $null
    )

    Invoke-P4 -P4Args @('submit', '-c', "$Change") -ProcessObserver $ProcessObserver | Out-Null
}

function Remove-P4ShelvedFiles {
    <#
    .SYNOPSIS
        Deletes shelved files from a pending changelist.
    .DESCRIPTION
        Runs 'p4 shelve -d -c <change>' to remove all shelved files associated
        with the specified pending changelist.
    .PARAMETER Change
        The pending changelist number whose shelved files should be deleted.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Change,
        [scriptblock]$ProcessObserver = $null
    )

    Invoke-P4 -P4Args @('shelve', '-d', '-c', "$Change") -ProcessObserver $ProcessObserver | Out-Null
}

function Get-P4SubmittedChangelists {
    <#
    .SYNOPSIS
        Returns submitted changelists, optionally paginated by change number.
    .DESCRIPTION
        Fetches submitted changelists limited to the current workspace mapping
        (or to the explicitly provided client workspace).
        When BeforeChange > 0, returns only changes with numbers less than BeforeChange.
    .PARAMETER Max
        Maximum number of changelists to return. Defaults to 50.
    .PARAMETER BeforeChange
        When greater than 0, fetches changes with numbers less than this value (pagination).
    .PARAMETER Client
        The Perforce client workspace whose mapping should limit the submitted
        changelist query. When omitted, the current client from Get-P4Info is used.
    #>
    [CmdletBinding()]
    param(
        [int]$Max = 50,
        [int]$BeforeChange = 0,
        [string]$Client = '',
        [scriptblock]$ProcessObserver = $null
    )

    if ([string]::IsNullOrWhiteSpace($Client)) {
        $info = Get-P4Info -ProcessObserver $ProcessObserver
        $Client = [string]$info.Client
    }

    $workspaceSpec = "//$Client/..."
    $querySpec = if ($BeforeChange -gt 0) { "$workspaceSpec@<$BeforeChange" } else { $workspaceSpec }

    $p4Args = @('changes', '-l', '-s', 'submitted', '-m', "$Max", $querySpec)

    $lines = Invoke-P4 -P4Args $p4Args -ProcessObserver $ProcessObserver
    $records = $lines

    $result = foreach ($record in $records) {
        if ($null -eq $record.change) { continue }
        if ($null -eq $record.time) { continue }

        $changeId = ConvertTo-P4ChangelistId -Value $record.change
        if ([string]::IsNullOrWhiteSpace($changeId)) { continue }

        $timestamp = [double]$record.time
        $time = [datetime]::UnixEpoch.AddSeconds($timestamp).ToLocalTime()

        $desc = [string]$record.desc
        if ([string]::IsNullOrWhiteSpace($desc)) { $desc = '(no description)' }
        New-P4ChangelistRecord `
            -Change $changeId `
            -User ([string]$record.user) `
            -Client ([string]$record.client) `
            -Time $time `
            -Status 'submitted' `
            -Description $desc
    }

    return @($result | Sort-Object Time -Descending)
}

function Get-P4SubmittedChangelistEntries {
    <#
    .SYNOPSIS
        Returns ChangelistEntry objects for submitted changelists, optionally paginated.
    .PARAMETER Max
        Maximum number of entries to return. Defaults to 50.
    .PARAMETER BeforeChange
        When greater than 0, fetches changes with numbers less than this value (pagination).
    .PARAMETER Client
        The Perforce client workspace whose mapping should limit the submitted
        changelist query. When omitted, the current client from Get-P4Info is used.
    #>
    [CmdletBinding()]
    param(
        [int]$Max = 50,
        [int]$BeforeChange = 0,
        [string]$Client = '',
        [scriptblock]$ProcessObserver = $null
    )

    $changelists = Get-P4SubmittedChangelists -Max $Max -BeforeChange $BeforeChange -Client $Client -ProcessObserver $ProcessObserver

    $changelists | ForEach-Object {
        ConvertTo-SubmittedChangelistEntry -Changelist $_
    }
}

function Invoke-P4ReopenFiles {
    <#
    .SYNOPSIS
        Moves all opened files from a source pending changelist to a target pending changelist.
    .DESCRIPTION
        Fetches all opened files in SourceChange using Get-P4OpenedFiles, then runs
        'p4 reopen -c <TargetChange> <depotPaths...>' to reassign them.
        Returns a hashtable with MovedCount (int) and Files (string[]).
        If the source changelist has no opened files, returns MovedCount=0 immediately
        without calling p4 reopen.
    .PARAMETER SourceChange
        The changelist number whose opened files should be moved.
    .PARAMETER TargetChange
        The destination changelist number.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceChange,
        [Parameter(Mandatory)][string]$TargetChange,
        [scriptblock]$ProcessObserver = $null
    )

    $files = @(Get-P4OpenedFiles -Change $SourceChange -ProcessObserver $ProcessObserver)
    if ($files.Count -eq 0) {
        return @{ MovedCount = 0; Files = @() }
    }

    [string[]]$depotPaths = @($files | ForEach-Object { [string]$_.DepotPath })
    Invoke-P4 -P4Args (@('reopen', '-c', "$TargetChange") + $depotPaths) -ProcessObserver $ProcessObserver | Out-Null

    return @{ MovedCount = $depotPaths.Count; Files = $depotPaths }
}

# ── Resolve ───────────────────────────────────────────────────────────────────

function Invoke-P4Resolve {
    <#
    .SYNOPSIS
        Runs `p4 resolve <depot-path>` directly, without -ztag/-Mj flags.
    .DESCRIPTION
        Calls p4.exe directly (not via Invoke-P4) because:
          1. `p4 resolve` must not receive -ztag -Mj flags.
          2. The wait is unlimited — the user drives an external merge tool.
        Notifies the registered P4 execution observer so command logging works.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DepotPath,
        [scriptblock]$ProcessObserver = $null
    )

    $p4Args      = @('resolve', $DepotPath)
    $commandLine = Format-P4CommandLine -P4Args $p4Args

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = $script:P4Executable
    $psi.Arguments              = $commandLine.Substring(3)   # strip 'p4 '
    $psi.WorkingDirectory       = (Get-Location).Path
    $psi.RedirectStandardInput  = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi

    $startedAt = Get-Date
    if (-not $process.Start()) { throw 'Failed to start p4.exe' }

    if ($ProcessObserver) {
        try { & $ProcessObserver -EventType 'ProcessStarted' -ProcessId $process.Id -ExitCode $null } catch { }
    }

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    # Unlimited wait — the user must close the external merge tool before we continue.
    $process.WaitForExit()

    $stdout   = $stdoutTask.GetAwaiter().GetResult()
    $stderr   = $stderrTask.GetAwaiter().GetResult()
    $exitCode = $process.ExitCode

    if ($ProcessObserver) {
        try { & $ProcessObserver -EventType 'ProcessFinished' -ProcessId $process.Id -ExitCode $exitCode } catch { }
    }

    $endedAt    = Get-Date
    $durationMs = [int](($endedAt - $startedAt).TotalMilliseconds)

    $effectiveObserver = $script:P4ExecutionObserver
    if ($effectiveObserver) {
        try {
            & $effectiveObserver `
                -CommandLine  $commandLine `
                -RawLines     @() `
                -ExitCode     $exitCode `
                -ErrorOutput  $stderr `
                -StartedAt    $startedAt `
                -EndedAt      $endedAt `
                -DurationMs   $durationMs
        } catch { }
    }

    $process.Dispose()

    if ($exitCode -ne 0) {
        $msg = "p4 resolve failed (exit $exitCode)."
        if (-not [string]::IsNullOrWhiteSpace($stderr))  { $msg += " STDERR: $stderr" }
        elseif (-not [string]::IsNullOrWhiteSpace($stdout)) { $msg += " STDOUT: $stdout" }
        throw $msg
    }
}

# ── Merge tool configuration ──────────────────────────────────────────────────
# Predefined presets.  These are convenience defaults; the persisted value is
# always the P4MERGE Perforce variable written via `p4 set`.

$script:MergeToolPresets = @(
    [pscustomobject]@{
        Name = 'P4Merge'
        Path = 'C:\Program Files\Perforce\p4merge.exe'
        Args = ''
    },
    [pscustomobject]@{
        Name = 'Beyond Compare'
        Path = 'C:\Program Files\Beyond Compare 5\BCompare.exe'
        Args = '%1 %2 %b %r'
    },
    [pscustomobject]@{
        Name = 'KDiff3'
        Path = 'C:\Program Files\KDiff3\kdiff3.exe'
        Args = '%b %1 %2 -o %r'
    }
)

function Get-P4MergeToolPresets {
    <#
    .SYNOPSIS
        Returns the built-in array of merge tool presets.
    #>
    $script:MergeToolPresets
}

function Get-P4MergeTool {
    <#
    .SYNOPSIS
        Reads the current P4MERGE setting via `p4 set P4MERGE`.
    .DESCRIPTION
        Calls `p4 set` directly (not through Invoke-P4) because `p4 set` does
        not produce -ztag -Mj JSON output.
        Returns a PSObject with Path (string) and IsSet (bool).
    #>
    $output    = & $script:P4Executable 'set' 'P4MERGE' 2>&1
    $outputStr = [string]$output
    if ($outputStr -match 'P4MERGE=(.+?)(\s+\(set\))?\s*$') {
        return [pscustomobject]@{ Path = $Matches[1].Trim(); IsSet = $true }
    }
    return [pscustomobject]@{ Path = ''; IsSet = $false }
}

function Set-P4MergeTool {
    <#
    .SYNOPSIS
        Persists a merge tool path via `p4 set P4MERGE=<ToolPath>`.
    .DESCRIPTION
        Calls `p4 set` directly (not through Invoke-P4) because `p4 set` does
        not produce -ztag -Mj JSON output.
    #>
    param(
        [Parameter(Mandatory)][string]$ToolPath
    )
    & $script:P4Executable 'set' "P4MERGE=$ToolPath" 2>&1 | Out-Null
}

function Get-P4FileLog {
    <#
    .SYNOPSIS
        Returns RevisionNode objects for a depot file's revision history.
    .DESCRIPTION
        Invokes 'p4 filelog -l -m $Limit <depotFile>' and parses the structured
        output into RevisionNode objects with nested IntegrationRecord arrays.
    .PARAMETER DepotFile
        Full depot path (e.g. //depot/main/foo.cpp).
    .PARAMETER Limit
        Maximum number of revisions to fetch (newest first).
    .PARAMETER ProcessObserver
        Optional per-invocation process lifecycle callback.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DepotFile,
        [int]$Limit = 30,
        [scriptblock]$ProcessObserver = $null
    )

    $records = Invoke-P4 -P4Args @('filelog', '-l', '-m', "$Limit", $DepotFile) `
                         -ProcessObserver $ProcessObserver

    $result = [System.Collections.Generic.List[object]]::new()

    foreach ($record in $records) {
        $depotFileProp = $record.PSObject.Properties['depotFile']
        if ($null -eq $depotFileProp) { continue }

        # Collect numbered integration fields (how0/file0/srev0/erev0, how1/..., ...)
        $integrations = [System.Collections.Generic.List[object]]::new()
        $idx = 0
        while ($null -ne $record.PSObject.Properties["how$idx"]) {
            $howProp  = $record.PSObject.Properties["how$idx"]
            $fileProp = $record.PSObject.Properties["file$idx"]
            $srevProp = $record.PSObject.Properties["srev$idx"]
            $erevProp = $record.PSObject.Properties["erev$idx"]
            if ($null -ne $howProp -and $null -ne $fileProp) {
                # srev/erev from p4 filelog -ztag may be "#N" or plain "N"
                $srevStr = if ($null -ne $srevProp) { ([string]$srevProp.Value) -replace '^#', '' } else { '0' }
                $erevStr = if ($null -ne $erevProp) { ([string]$erevProp.Value) -replace '^#', '' } else { '0' }
                $srevInt = 0
                $erevInt = 0
                [void][int]::TryParse($srevStr, [ref]$srevInt)
                [void][int]::TryParse($erevStr, [ref]$erevInt)
                $integrations.Add(
                    (New-IntegrationRecord -How ([string]$howProp.Value) -File ([string]$fileProp.Value) `
                        -StartRev $srevInt -EndRev $erevInt)
                ) | Out-Null
            }
            $idx++
        }

        $revProp    = $record.PSObject.Properties['rev']
        $changeProp = $record.PSObject.Properties['change']
        $actionProp = $record.PSObject.Properties['action']
        $typeProp   = $record.PSObject.Properties['type']
        $timeProp   = $record.PSObject.Properties['time']
        $userProp   = $record.PSObject.Properties['user']
        $clientProp = $record.PSObject.Properties['client']
        $descProp   = $record.PSObject.Properties['desc']

        $revInt    = 0
        $changeInt = 0
        $timeInt   = 0
        $revStr    = if ($null -ne $revProp)    { [string]$revProp.Value    } else { '' }
        $changeStr = if ($null -ne $changeProp) { [string]$changeProp.Value } else { '' }
        $timeStr   = if ($null -ne $timeProp)   { [string]$timeProp.Value   } else { '' }
        [void][int]::TryParse($revStr,    [ref]$revInt)
        [void][int]::TryParse($changeStr, [ref]$changeInt)
        [void][int]::TryParse($timeStr,   [ref]$timeInt)

        $nodeAction   = if ($null -ne $actionProp) { [string]$actionProp.Value } else { '' }
        $nodeFileType = if ($null -ne $typeProp)   { [string]$typeProp.Value   } else { '' }
        $nodeUser     = if ($null -ne $userProp)   { [string]$userProp.Value   } else { '' }
        $nodeClient   = if ($null -ne $clientProp) { [string]$clientProp.Value } else { '' }
        $nodeDesc     = if ($null -ne $descProp)   { [string]$descProp.Value   } else { '' }
        $result.Add((New-RevisionNode `
            -DepotFile    ([string]$depotFileProp.Value) `
            -Rev          $revInt `
            -Change       $changeInt `
            -Action       $nodeAction `
            -FileType     $nodeFileType `
            -Time         $timeInt `
            -User         $nodeUser `
            -Client       $nodeClient `
            -Description  $nodeDesc `
            -Integrations @($integrations.ToArray())
        )) | Out-Null
    }

    return @($result.ToArray())
}

Export-ModuleMember -Function ConvertTo-P4ChangelistId, Format-P4CommandLine, Format-P4OutputLine, Register-P4Observer, Unregister-P4Observer, Get-P4CommandCategory, Get-DurationClass, Get-P4CommandTimeout, Stop-P4ProcessTree, Test-IsP4TimeoutError, Invoke-P4, Get-P4Info, Get-P4PendingChangelists, Get-P4ChangelistEntries, Get-P4Describe, Get-P4OpenedChangeNumbers, Get-P4OpenedFileCounts, Get-P4ShelvedChangeNumbers, Get-P4ShelvedFileCounts, ConvertFrom-P4OpenedLinesToFileCounts, ConvertFrom-P4DescribeShelvedLinesToFileCounts, Test-IsP4NoUnresolvedFilesError, ConvertFrom-P4FstatUnresolvedRecordsToFileCounts, Get-P4UnresolvedFileCounts, Get-P4UnresolvedDepotPaths, Get-P4ModifiedDepotPaths, Set-P4FileEntriesUnresolvedState, Set-P4FileEntriesContentModifiedState, Remove-P4Changelist, Invoke-P4Submit, Invoke-P4ShelveFiles, Remove-P4ShelvedFiles, Get-P4SubmittedChangelists, Get-P4SubmittedChangelistEntries, Get-P4OpenedFiles, Invoke-P4ReopenFiles, `
    Get-P4MergeToolPresets, Get-P4MergeTool, Set-P4MergeTool, Invoke-P4Resolve, `
    Get-P4FileLog
