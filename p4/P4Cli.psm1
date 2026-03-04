Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Models.psm1') -Force

function Invoke-P4 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$P4Args
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'p4.exe'
    $psi.Arguments = ($P4Args | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    $psi.WorkingDirectory = (Get-Location).Path
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi

    if (-not $process.Start()) {
        throw 'Failed to start p4.exe'
    }

    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    if ($process.ExitCode -ne 0) {
        $messageParts = @(
            "p4 failed (exit $($process.ExitCode)).",
            "Args: $($psi.Arguments)"
        )
        if ($stderr) { $messageParts += "STDERR: $stderr" }
        if ($stdout) { $messageParts += "STDOUT: $stdout" }

        throw ($messageParts -join "`n")
    }

    return ($stdout -split "`r?`n") | Where-Object { $_ -ne '' }
}

function Get-P4Info {
    [CmdletBinding()]
    param()

    $lines = Invoke-P4 -P4Args @('-ztag', 'info')

    $kv = @{}
    foreach ($line in $lines) {
        if ($line -match '^\.\.\.\s+(?<k>\S+)\s+(?<v>.*)$') {
            $kv[$Matches.k] = $Matches.v
        }
    }

    [pscustomobject]@{
        User   = [string]$kv.userName
        Client = [string]$kv.clientName
        Port   = [string]$kv.serverAddress
        Root   = [string]$kv.clientRoot
    }
}

function ConvertFrom-P4ZTagRecords {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Lines
    )

    $records = @()
    $current = @{}

    foreach ($line in $Lines) {
        if ($line -match '^\.\.\.\s+(?<k>\S+)\s+(?<v>.*)$') {
            $k = $Matches.k
            $v = $Matches.v

            if ($current.ContainsKey($k)) {
                $records += ,$current
                $current = @{}
            }
            $current[$k] = $v
        }
    }

    if ($current.Count -gt 0) {
        $records += ,$current
    }

    return $records
}

function Get-P4PendingChangelists {
    [CmdletBinding()]
    param(
        [int]$Max = 200
    )

    $info = Get-P4Info
    $lines = Invoke-P4 -P4Args @(
        '-ztag', 'changes',
        '-s', 'pending',
        '-u', $info.User,
        '-c', $info.Client,
        '-m', "$Max"
    )

    $records = ConvertFrom-P4ZTagRecords -Lines $lines
    $result = foreach ($record in $records) {
        if (-not $record.ContainsKey('change')) { continue }
        if (-not $record.ContainsKey('time')) { continue }

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

    $changelists = Get-P4PendingChangelists -Max $Max
    $openedSet = Get-P4OpenedChangeNumbers
    $shelvedSet = Get-P4ShelvedChangeNumbers
    if ($null -eq $openedSet) { $openedSet = [System.Collections.Generic.HashSet[int]]::new() }
    if ($null -eq $shelvedSet) { $shelvedSet = [System.Collections.Generic.HashSet[int]]::new() }

    $changelists | ForEach-Object {
        $isEmpty = -not $openedSet.Contains([int]$_.Change) -and -not $shelvedSet.Contains([int]$_.Change)
        ConvertTo-ChangelistEntry -Changelist $_ -IsEmpty $isEmpty
    }
}

function Get-P4Describe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Change
    )

    $lines = Invoke-P4 -P4Args @('-ztag', 'describe', '-s', "$Change")

    # Parse all ztag key-value pairs into a single flat hashtable.
    $kv = @{}
    foreach ($line in $lines) {
        if ($line -match '^\.\.\.\s+(?<k>\S+)\s+(?<v>.*)$') {
            $kv[$Matches.k] = $Matches.v
        }
    }

    if (-not $kv.ContainsKey('change')) {
        throw "Failed to parse describe output for CL $Change"
    }

    $time = if ($kv.ContainsKey('time')) {
        ([datetime]'1970-01-01T00:00:00Z').AddSeconds([double]$kv.time).ToLocalTime()
    } else { Get-Date }

    $descText  = if ($kv.ContainsKey('desc')) { $kv.desc } else { '' }
    $descLines = if ($descText) { $descText -split "`r?`n" } else { @() }

    # Extract indexed file entries: depotFile0/action0/type0, depotFile1/action1/type1, ...
    $files = @()
    for ($i = 0; ; $i++) {
        $depotKey = "depotFile$i"
        if (-not $kv.ContainsKey($depotKey)) { break }
        $files += [pscustomobject]@{
            DepotPath = [string]$kv[$depotKey]
            Action    = if ($kv.ContainsKey("action$i")) { [string]$kv["action$i"] } else { '' }
            Type      = if ($kv.ContainsKey("type$i"))   { [string]$kv["type$i"]   } else { '' }
        }
    }

    [pscustomobject]@{
        Change      = [int]$kv.change
        User        = [string]$kv.user
        Client      = [string]$kv.client
        Status      = [string]$kv.status
        Time        = $time
        Description = @($descLines | Where-Object { $_ -ne '' })
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

function Get-P4OpenedChangeNumbers {
    <#
    .SYNOPSIS
        Returns the set of changelist numbers that have at least one opened file.
    .DESCRIPTION
        Runs 'p4 -ztag opened -u <user> -c <client>' once to get all open files,
        then extracts the distinct changelist numbers.
    #>
    [CmdletBinding()]
    param()

    try {
        $lines = Invoke-P4 -P4Args @('-ztag', 'opened')
    }
    catch {
        $errorMessage = [string]$_.Exception.Message
        if (-not (Test-IsP4NoOpenedFilesError -Message $errorMessage)) {
            throw
        }
        # No files opened is not an error
        return ,([System.Collections.Generic.HashSet[int]]::new())
    }

    $result = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($line in $lines) {
        if ($line -match '^\.\.\.\s+change\s+(\d+)') {
            [void]$result.Add([int]$Matches[1])
        }
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
        $lines = Invoke-P4 -P4Args @('-ztag', 'changes', '-s', 'shelved', '-u', $info.User, '-c', $info.Client)
    }
    catch {
        $errorMessage = [string]$_.Exception.Message
        if (-not (Test-IsP4NoShelvedChangesError -Message $errorMessage)) {
            throw
        }
        return ,([System.Collections.Generic.HashSet[int]]::new())
    }

    $result = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($line in $lines) {
        if ($line -match '^\.\.\.\s+change\s+(\d+)') {
            [void]$result.Add([int]$Matches[1])
        }
    }

    return ,$result
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

Export-ModuleMember -Function Invoke-P4, Get-P4Info, Get-P4PendingChangelists, Get-P4ChangelistEntries, Get-P4Describe, Get-P4OpenedChangeNumbers, Get-P4ShelvedChangeNumbers, Remove-P4Changelist
