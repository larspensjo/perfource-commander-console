#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [int]$MaxChanges = 200
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'PerfourceCommanderConsole.psd1') -Force

Start-P4Browser -MaxChanges $MaxChanges
