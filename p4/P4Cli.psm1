Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Models.psm1') -Force

function Invoke-P4 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Args
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'p4.exe'
    $psi.Arguments = ($Args | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
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

    $lines = Invoke-P4 -Args @('-ztag', 'info')

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
    $lines = Invoke-P4 -Args @(
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

function Get-P4PendingChangelistIdeaLikeEntries {
    [CmdletBinding()]
    param(
        [int]$Max = 200
    )

    Get-P4PendingChangelists -Max $Max |
        ForEach-Object { ConvertTo-IdeaLikeEntryFromP4Changelist -Changelist $_ }
}

Export-ModuleMember -Function Invoke-P4, Get-P4Info, Get-P4PendingChangelists, Get-P4PendingChangelistIdeaLikeEntries
