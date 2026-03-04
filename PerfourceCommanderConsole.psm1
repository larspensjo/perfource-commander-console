Set-StrictMode -Version Latest

# Import sub-modules; each handles its own internal dependencies via $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'p4\Models.psm1')    -Force
Import-Module (Join-Path $PSScriptRoot 'p4\P4Cli.psm1')     -Force
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

    $previousOutputEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

    $previousCursorVisible = [Console]::CursorVisible
    [Console]::CursorVisible = $false

    try {
        # Initial load
        $loadCmdLine = "p4 changes -s pending -m $MaxChanges"
        $state = Invoke-BrowserSideEffect -State $state -CommandLine $loadCmdLine -WorkItem {
            param($s)
            $fresh = Get-P4ChangelistEntries -Max $MaxChanges
            $s.Data.AllChanges = @($fresh)
            $filterUniverse = @($s.Data.AllChanges | ForEach-Object { @($_.Filters) })
            $s.Data.AllFilters = @(
                $filterUniverse |
                    Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
                    Sort-Object -Unique
            )
            $s.Runtime.LastError = $null
            return Update-BrowserDerivedState -State $s
        }

        while ($state.Runtime.IsRunning) {
            $currentWidth  = [Console]::WindowWidth
            $currentHeight = [Console]::WindowHeight
            if ($state.Ui.Layout.Width -ne $currentWidth -or $state.Ui.Layout.Height -ne $currentHeight) {
                $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
                    Type   = 'Resize'
                    Width  = $currentWidth
                    Height = $currentHeight
                })
            }

            Render-BrowserState -State $state
            $keyInfo = [Console]::ReadKey($true)
            $action  = ConvertFrom-KeyInfoToAction -KeyInfo $keyInfo
            if ($null -ne $action) {
                $state = Invoke-BrowserReducer -State $state -Action $action

                # Handle reload flag (Reload I/O lives outside the reducer for purity)
                if ($state.Runtime.ReloadRequested) {
                    $state.Runtime.ReloadRequested = $false
                    $reloadCmdLine = "p4 changes -s pending -m 200"
                    $state = Invoke-BrowserSideEffect -State $state -CommandLine $reloadCmdLine -WorkItem {
                        param($s)
                        $fresh = Get-P4ChangelistEntries -Max 200
                        $s.Data.AllChanges = @($fresh)
                        $filterUniverse = @($s.Data.AllChanges | ForEach-Object { @($_.Filters) })
                        $filterUniverse += @($s.Query.SelectedFilters)
                        $s.Data.AllFilters = @(
                            $filterUniverse |
                                Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
                                Sort-Object -Unique
                        )
                        $s.Runtime.LastError = $null
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
                            $deletedId = "CL-$change"
                            $s.Data.AllChanges = @($s.Data.AllChanges | Where-Object { $_.Id -ne $deletedId })
                            $filterUniverse = @($s.Data.AllChanges | ForEach-Object { @($_.Filters) })
                            if ($null -ne $s.Query -and $null -ne $s.Query.SelectedFilters) {
                                $filterUniverse += @($s.Query.SelectedFilters)
                            }
                            $s.Data.AllFilters = @(
                                $filterUniverse |
                                    Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
                                    Sort-Object -Unique
                            )
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
