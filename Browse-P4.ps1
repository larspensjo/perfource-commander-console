#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [int]$MaxChanges = 200
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'p4\Models.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'p4\P4Cli.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'tui\Reducer.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'tui\Input.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'tui\Render.psm1') -Force -DisableNameChecking

$ideas = Get-P4PendingChangelistIdeaLikeEntries -Max $MaxChanges

$width = [Console]::WindowWidth
$height = [Console]::WindowHeight
$state = New-BrowserState -Ideas $ideas -InitialWidth $width -InitialHeight $height

$previousCursorVisible = [Console]::CursorVisible
[Console]::CursorVisible = $false

try {
    while ($state.Runtime.IsRunning) {
        $currentWidth = [Console]::WindowWidth
        $currentHeight = [Console]::WindowHeight
        if ($state.Ui.Layout.Width -ne $currentWidth -or $state.Ui.Layout.Height -ne $currentHeight) {
            $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'Resize'; Width = $currentWidth; Height = $currentHeight })
        }

        Render-BrowserState -State $state
        $keyInfo = [Console]::ReadKey($true)
        $action = ConvertFrom-KeyInfoToAction -KeyInfo $keyInfo
        if ($null -ne $action) {
            $state = Invoke-BrowserReducer -State $state -Action $action
        }
    }
}
finally {
    [Console]::CursorVisible = $previousCursorVisible
    Clear-Host
}
