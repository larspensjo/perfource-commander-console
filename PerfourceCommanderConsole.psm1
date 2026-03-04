Set-StrictMode -Version Latest

# Import sub-modules; each handles its own internal dependencies via $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'p4\Models.psm1')    -Force
Import-Module (Join-Path $PSScriptRoot 'p4\P4Cli.psm1')     -Force
Import-Module (Join-Path $PSScriptRoot 'tui\Filtering.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'tui\Layout.psm1')    -Force
Import-Module (Join-Path $PSScriptRoot 'tui\Reducer.psm1')   -Force
Import-Module (Join-Path $PSScriptRoot 'tui\Input.psm1')     -Force
Import-Module (Join-Path $PSScriptRoot 'tui\Render.psm1')    -Force -DisableNameChecking

function Start-P4Browser {
    <#
    .SYNOPSIS
        Opens the Perforce TUI browser for pending changelists.
    .DESCRIPTION
        Launches an interactive terminal user interface for browsing and managing
        Perforce changelists, files, shelves, and streams. Keyboard-driven,
        Total Commander–inspired workflow.
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

    $changes = Get-P4ChangelistEntries -Max $MaxChanges

    $width  = [Console]::WindowWidth
    $height = [Console]::WindowHeight
    $state  = New-BrowserState -Changes $changes -InitialWidth $width -InitialHeight $height

    $previousOutputEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

    $previousCursorVisible = [Console]::CursorVisible
    [Console]::CursorVisible = $false

    try {
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

                # Fetch describe on-demand (I/O lives outside the reducer to keep it pure)
                if (-not [string]::IsNullOrWhiteSpace([string]$state.Runtime.LastSelectedId)) {
                    $change = ConvertTo-ChangeNumberFromId -Id $state.Runtime.LastSelectedId
                    if ($null -ne $change -and -not $state.Data.DescribeCache.ContainsKey($change)) {
                        try {
                            $state.Data.DescribeCache[$change] = Get-P4Describe -Change $change
                            $state.Runtime.LastError = $null
                        } catch {
                            $state.Runtime.LastError = $_.Exception.Message
                        }
                    }
                }

                # Delete changelist on-demand
                if (-not [string]::IsNullOrWhiteSpace([string]$state.Runtime.DeleteChangeId)) {
                    $change = ConvertTo-ChangeNumberFromId -Id $state.Runtime.DeleteChangeId
                    $state.Runtime.DeleteChangeId = $null
                    if ($null -ne $change) {
                        try {
                            Remove-P4Changelist -Change $change
                            # Remove from local state without full reload
                            $deletedId = "CL-$change"
                            $state.Data.AllChanges = @($state.Data.AllChanges | Where-Object { $_.Id -ne $deletedId })
                            $filterUniverse = @(
                                $state.Data.AllChanges |
                                    ForEach-Object { @($_.Filters) }
                            )
                            if ($null -ne $state.Query -and $null -ne $state.Query.SelectedFilters) {
                                $filterUniverse += @($state.Query.SelectedFilters)
                            }
                            $state.Data.AllFilters = @(
                                $filterUniverse |
                                    Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
                                    Sort-Object -Unique
                            )
                            $state.Data.DescribeCache.Remove($change) | Out-Null
                            $state = Update-BrowserDerivedState -State $state
                            $state.Runtime.LastError = $null
                        } catch {
                            $state.Runtime.LastError = $_.Exception.Message
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
