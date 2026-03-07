Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Models.psm1') -Force

# Overridable in tests via InModuleScope P4Cli { $script:P4Executable = 'cmd.exe' }
$script:P4Executable = 'p4.exe'

# Maximum number of formatted output lines to store per command invocation.
$script:CommandOutputMaxLines = 2000

# Observer scriptblock invoked after each Invoke-P4 call.
# Signature: { param($CommandLine,$RawLines,$ExitCode,$ErrorOutput,$StartedAt,$EndedAt,$DurationMs) }
[scriptblock]$script:P4ExecutionObserver = $null

function Format-P4CommandLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$P4Args
    )
    $quoted = $P4Args | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
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

function Invoke-P4 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$P4Args,
        # Milliseconds to wait before killing the p4 process. Defaults to 30 s.
        [int]$TimeoutMs = 30000
    )

    $globalArgs = @('-ztag', '-Mj')
    $fullArgs = $globalArgs + $P4Args
    $commandLine = Format-P4CommandLine -P4Args $fullArgs

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $script:P4Executable
    $psi.Arguments = $commandLine.Substring(3)  # strip leading 'p4 '
    $psi.WorkingDirectory = (Get-Location).Path
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

    # Read stdout and stderr concurrently via async tasks to prevent the
    # deadlock that can occur when one pipe's buffer fills before the other
    # is drained.  WaitForExit(timeout) then gives us a hard upper bound on
    # how long a stalled p4 call can block the UI.
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    $exited = $process.WaitForExit($TimeoutMs)

    if (-not $exited) {
        # Kill the entire process tree (not just the root) so child processes
        # such as p4d helpers don't keep stdout/stderr pipe handles open.
        # Process.Kill() alone only terminates the direct process; on Windows
        # this leaves children alive and leaks pipe handles / async tasks.
        try { $null = & taskkill /F /T /PID $process.Id 2>&1 } catch { <# best-effort #> }
        try { if (-not $process.HasExited) { $process.Kill() } } catch { <# fallback #> }
        # Dispose closes the redirected stream handles so ReadToEndAsync tasks
        # complete promptly instead of dangling until GC finalizes them.
        try { $process.Dispose() } catch { <# best-effort #> }
        throw "p4 timed out after ${TimeoutMs} ms. Args: $($psi.Arguments)"
    }

    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $exitCode = $process.ExitCode
    $process.Dispose()

    $rawLines  = @(($stdout -split "`r?`n") | Where-Object { $_ -ne '' })
    $endedAt   = Get-Date
    $durationMs = [int](($endedAt - $startedAt).TotalMilliseconds)

    if ($script:P4ExecutionObserver) {
        try {
            & $script:P4ExecutionObserver -CommandLine $commandLine -RawLines $rawLines `
                -ExitCode $exitCode -ErrorOutput $stderr `
                -StartedAt $startedAt -EndedAt $endedAt -DurationMs $durationMs
        } catch { <# observer must not break p4 operations #> }
    }

    if ($exitCode -ne 0) {
        $messageParts = @(
            "p4 failed (exit $exitCode).",
            "Args: $($psi.Arguments)"
        )
        if ($stderr) { $messageParts += "STDERR: $stderr" }
        if ($stdout) { $messageParts += "STDOUT: $stdout" }

        throw ($messageParts -join "`n")
    }

    return @($rawLines | ForEach-Object { ConvertFrom-Json $_ })
}

function Get-P4Info {
    [CmdletBinding()]
    param()

    $lines = Invoke-P4 -P4Args @('info')

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
        [int]$Max = 200
    )

    $info = Get-P4Info
    $lines = Invoke-P4 -P4Args @(
        'changes',
        '-l',
        '-s', 'pending',
        '-u', $info.User,
        '-c', $info.Client,
        '-m', "$Max"
    )

    $records = $lines
    $result = foreach ($record in $records) {
        if ($null -eq $record.change) { continue }
        if ($null -eq $record.time) { continue }

        $timestamp = [double]$record.time
        $time = [datetime]::UnixEpoch.AddSeconds($timestamp).ToLocalTime()

        New-P4Changelist `
            -Change ([int]$record.change) `
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
        [int]$Max = 200
    )

    $changelists  = Get-P4PendingChangelists -Max $Max
    $openedCounts = Get-P4OpenedFileCounts
    $changeNumbers = @($changelists | ForEach-Object { [int]$_.Change })
    $shelvedCounts = Get-P4ShelvedFileCounts -ChangeNumbers $changeNumbers

    $changelists | ForEach-Object {
        $changeNum    = [int]$_.Change
        $openedCount  = if ($openedCounts.ContainsKey($changeNum))  { $openedCounts[$changeNum]  } else { 0 }
        $shelvedCount = if ($shelvedCounts.ContainsKey($changeNum)) { $shelvedCounts[$changeNum] } else { 0 }
        ConvertTo-ChangelistEntry -Changelist $_ -OpenedFileCount $openedCount -ShelvedFileCount $shelvedCount
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
            $index = [int]$prop.Name.Substring('depotFile'.Length)
            $actionProp = $Record.PSObject.Properties["action$index"]
            $typeProp   = $Record.PSObject.Properties["type$index"]
            $files.Add([pscustomobject]@{
                DepotPath = [string]$prop.Value
                Action    = if ($null -ne $actionProp) { [string]$actionProp.Value } else { '' }
                Type      = if ($null -ne $typeProp)   { [string]$typeProp.Value }   else { '' }
            }) | Out-Null
        }

        return @($files.ToArray())
    }

    if ($null -ne ($Record.PSObject.Properties['depotFile'])) {
        $depotFiles = @($Record.depotFile)
        $actions    = if ($null -ne ($Record.PSObject.Properties['action'])) { @($Record.action) } else { @() }
        $types      = if ($null -ne ($Record.PSObject.Properties['type']))   { @($Record.type)   } else { @() }

        for ($i = 0; $i -lt $depotFiles.Count; $i++) {
            $files.Add([pscustomobject]@{
                DepotPath = [string]$depotFiles[$i]
                Action    = if ($i -lt $actions.Count) { [string]$actions[$i] } else { '' }
                Type      = if ($i -lt $types.Count)   { [string]$types[$i]   } else { '' }
            }) | Out-Null
        }
    }

    return @($files.ToArray())
}

function Get-P4Describe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Change
    )

    $lines = Invoke-P4 -P4Args @('describe', '-s', "$Change")

    $record = $lines | Select-Object -First 1
    if ($null -eq $record -or $null -eq ($record.PSObject.Properties['change'])) {
        throw "Failed to parse describe output for CL $Change"
    }

    $time = if ($null -ne ($record.PSObject.Properties['time'])) {
        ([datetime]'1970-01-01T00:00:00Z').AddSeconds([double]$record.time).ToLocalTime()
    } else { Get-Date }

    $files = @(ConvertFrom-P4DescribeRecordToFiles -Record $record)

    $descLines = @([string]$record.desc -split "`r?`n" | Where-Object { $_ -ne '' })

    [pscustomobject]@{
        Change      = [int]$record.change
        User        = [string]$record.user
        Client      = [string]$record.client
        Status      = [string]$record.status
        Time        = $time
        Description = $descLines
        Files       = @($files)
    }
}

function Test-IsP4NoOpenedFilesError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message
    )

    return ($Message -match '(?i)file\(s\)\s+not\s+opened|no\s+such\s+file\(s\)')
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

    $result = [System.Collections.Generic.Dictionary[int,int]]::new()
    foreach ($record in $Records) {
        if ($null -eq ($record.PSObject.Properties['change'])) { continue }
        $change = [int]$record.change
        if ($result.ContainsKey($change)) { $result[$change]++ } else { $result[$change] = 1 }
    }
    return $result
}

# Pure helper: count shelved files per changelist from 'p4 -ztag -Mj describe -S -s' JSON output.
# Each PSObject record is one changelist; depotFile is a (possibly array) property.
function ConvertFrom-P4DescribeShelvedLinesToFileCounts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records
    )

    $result = [System.Collections.Generic.Dictionary[int,int]]::new()
    foreach ($record in $Records) {
        if ($null -eq ($record.PSObject.Properties['change'])) { continue }
        $change    = [int]$record.change
        $fileCount = if ($null -ne ($record.PSObject.Properties['depotFile'])) { @($record.depotFile).Count } else { 0 }
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
    param()

    try {
        $lines = Invoke-P4 -P4Args @('opened')
    }
    catch {
        $errorMessage = [string]$_.Exception.Message
        if (-not (Test-IsP4NoOpenedFilesError -Message $errorMessage)) {
            throw
        }
        # No files opened is not an error
        return [System.Collections.Generic.Dictionary[int,int]]::new()
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
    $result = [System.Collections.Generic.HashSet[int]]::new()
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
        return ,([System.Collections.Generic.HashSet[int]]::new())
    }

    $result = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($record in $lines) {
        if ($null -ne ($record.PSObject.Properties['change'])) { [void]$result.Add([int]$record.change) }
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
        [Parameter(Mandatory)][AllowEmptyCollection()][int[]]$ChangeNumbers
    )

    $result = [System.Collections.Generic.Dictionary[int,int]]::new()
    if ($null -eq $ChangeNumbers -or $ChangeNumbers.Count -eq 0) {
        return $result
    }

    $chunkSize = 50
    for ($i = 0; $i -lt $ChangeNumbers.Count; $i += $chunkSize) {
        $end   = [Math]::Min($i + $chunkSize - 1, $ChangeNumbers.Count - 1)
        $chunk = $ChangeNumbers[$i..$end]
        $p4Args = @('describe', '-S', '-s') + @($chunk | ForEach-Object { "$_" })
        try {
            $lines = Invoke-P4 -P4Args $p4Args
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
        Calls 'p4 -ztag -Mj opened -c <cl>' (global flags added by Invoke-P4) and returns parsed PSObjects as FileEntry objects.
        An empty changelist (no opened files) returns an empty array without throwing.
    .PARAMETER Change
        The changelist number whose opened files to retrieve.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Change
    )

    $lines = @()
    try {
        $lines = @(Invoke-P4 -P4Args @('opened', '-c', "$Change"))
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
        $recChange = if ($null -ne ($record.PSObject.Properties['change'])) { [int]$record.change    } else { $Change }
        New-P4FileEntry -DepotPath $depotPath -Action $action -FileType $fileType `
                        -Change $recChange -SourceKind 'Opened'
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
        [Parameter(Mandatory)][int]$Change
    )

    Invoke-P4 -P4Args @('change', '-d', "$Change") | Out-Null
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
        [string]$Client = ''
    )

    if ([string]::IsNullOrWhiteSpace($Client)) {
        $info = Get-P4Info
        $Client = [string]$info.Client
    }

    $workspaceSpec = "//$Client/..."
    $querySpec = if ($BeforeChange -gt 0) { "$workspaceSpec@<$BeforeChange" } else { $workspaceSpec }

    $p4Args = @('changes', '-l', '-s', 'submitted', '-m', "$Max", $querySpec)

    $lines = Invoke-P4 -P4Args $p4Args
    $records = $lines

    $result = foreach ($record in $records) {
        if ($null -eq $record.change) { continue }
        if ($null -eq $record.time) { continue }

        $timestamp = [double]$record.time
        $time = [datetime]::UnixEpoch.AddSeconds($timestamp).ToLocalTime()

        $desc = [string]$record.desc
        if ([string]::IsNullOrWhiteSpace($desc)) { $desc = '(no description)' }
        New-P4Changelist `
            -Change ([int]$record.change) `
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
        [string]$Client = ''
    )

    $changelists = Get-P4SubmittedChangelists -Max $Max -BeforeChange $BeforeChange -Client $Client

    $changelists | ForEach-Object {
        ConvertTo-SubmittedChangelistEntry -Changelist $_
    }
}

Export-ModuleMember -Function Format-P4CommandLine, Format-P4OutputLine, Register-P4Observer, Unregister-P4Observer, Invoke-P4, Get-P4Info, Get-P4PendingChangelists, Get-P4ChangelistEntries, Get-P4Describe, Get-P4OpenedChangeNumbers, Get-P4OpenedFileCounts, Get-P4ShelvedChangeNumbers, Get-P4ShelvedFileCounts, ConvertFrom-P4OpenedLinesToFileCounts, ConvertFrom-P4DescribeShelvedLinesToFileCounts, Remove-P4Changelist, Get-P4SubmittedChangelists, Get-P4SubmittedChangelistEntries, Get-P4OpenedFiles
