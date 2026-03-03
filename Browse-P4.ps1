#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$IdeasPath = (Join-Path $PSScriptRoot '..\docs\FutureIdeas.md')
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'common\IdeaDocCore.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'browser\Reducer.psm1')
Import-Module (Join-Path $PSScriptRoot 'browser\Input.psm1')
Import-Module (Join-Path $PSScriptRoot 'browser\Render.psm1') -Force -DisableNameChecking

$resolvedPath = Resolve-IdeaDocPath -Path $IdeasPath
$lines = Read-TextLines -Path $resolvedPath
$doc = ConvertFrom-IdeaDoc -Lines $lines

$width = [Console]::WindowWidth
$height = [Console]::WindowHeight
$state = New-BrowserState -Ideas $doc.Entries -InitialWidth $width -InitialHeight $height

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
