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
    $endedAt = Get-Date

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
    .EXAMPLE
        Start-P4Browser
    .EXAMPLE
        Start-P4Browser -MaxChanges 500
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [int]$MaxChanges = 200
    )

    $width  = [Console]::WindowWidth
    $height = [Console]::WindowHeight
    $state  = New-BrowserState -Changes @() -InitialWidth $width -InitialHeight $height

    # Phase 0.2: Store configured max for consistent reload behaviour
    $state.Runtime.ConfiguredMax = $MaxChanges

    $previousOutputEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

    $previousCursorVisible = [Console]::CursorVisible
    [Console]::CursorVisible = $false

    try {
        # Populate current user (needed for submitted view's "My changes" filter)
        try {
            $p4Info = Get-P4Info
            $state.Data.CurrentUser = $p4Info.User
        } catch {
            $state.Data.CurrentUser = ''
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
                if ([Console]::KeyAvailable) {
                    $keyInfo = [Console]::ReadKey($true)
                } else {
                    $currentWidth  = [Console]::WindowWidth
                    $currentHeight = [Console]::WindowHeight
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
                    $reloadSubmittedCmdLine = 'p4 changes -s submitted -m 50'
                    $state = Invoke-BrowserSideEffect -State $state -CommandLine $reloadSubmittedCmdLine -WorkItem {
                        param($s)
                        $fresh = Get-P4SubmittedChangelistEntries -Max 50
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
                    $loadMoreCmdLine = if ($null -ne $beforeChange) { "p4 changes -s submitted -m 50 //...@<$beforeChange" } else { 'p4 changes -s submitted -m 50' }
                    $state = Invoke-BrowserSideEffect -State $state -CommandLine $loadMoreCmdLine -WorkItem {
                        param($s)
                        $pageSize = 50
                        $bc       = $s.Data.SubmittedOldestId
                        $newEntries = if ($null -ne $bc) {
                            @(Get-P4SubmittedChangelistEntries -Max $pageSize -BeforeChange $bc)
                        } else {
                            @(Get-P4SubmittedChangelistEntries -Max $pageSize)
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
                            $s.Runtime.LastError = $null
                            return Update-BrowserDerivedState -State $s
                        }
                    }
                }
            }
        }
    }
    finally {
        [Console]::CursorVisible = $previousCursorVisible
        [Console]::OutputEncoding = $previousOutputEncoding
        Clear-Host
    }
}

Export-ModuleMember -Function Start-P4Browser
