#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [int]$MaxChanges = 200,

    [Parameter(Mandatory = $false)]
    [switch]$Profile,

    [Parameter(Mandatory = $false)]
    [string]$ProfilePath = '',

    [Parameter(Mandatory = $false)]
    [int]$ProfileThresholdMs = 20
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'PerfourceCommanderConsole.psd1') -Force

Start-P4Browser -MaxChanges $MaxChanges -Profile:$Profile -ProfilePath $ProfilePath -ProfileThresholdMs $ProfileThresholdMs
