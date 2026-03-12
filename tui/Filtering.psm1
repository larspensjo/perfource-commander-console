Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Theme.psm1') -Force

# Predicate registry for pending changelists
$script:PendingFilterPredicates = [ordered]@{
    'No shelved files'                                   = { param($entry) -not [bool]$entry.HasShelvedFiles }
    'No opened files'                                    = { param($entry) -not [bool]$entry.HasOpenedFiles  }
    (Get-BrowserUiTheme).Labels.FilterPendingUnresolved  = {
        param($entry)
        # Guard against legacy entry objects that pre-date the HasUnresolvedFiles field.
        $match = $entry.PSObject.Properties.Match('HasUnresolvedFiles')
        if ($match.Count -eq 0) { return $false }
        [bool]$match[0].Value
    }
}

# Build the predicate registry for submitted changelists, capturing the current user.
function Get-SubmittedFilterPredicates {
    param([string]$CurrentUser = '')

    $user = $CurrentUser

    $myChangesPred = { param($entry) [string]$entry.User -eq $user }.GetNewClosure()

    $todayPred = {
        param($entry)
        $cap = $null
        try { $cap = [datetime]$entry.Captured } catch {}
        if ($null -eq $cap) { return $false }
        return $cap.Date -eq [datetime]::Today
    }

    $thisWeekPred = {
        param($entry)
        $cap = $null
        try { $cap = [datetime]$entry.Captured } catch {}
        if ($null -eq $cap) { return $false }
        return $cap -ge [datetime]::Today.AddDays(-7)
    }

    return [ordered]@{
        'My changes' = $myChangesPred
        'Today'      = $todayPred
        'This week'  = $thisWeekPred
    }
}

function Get-CommandLogFilterPredicates {
    <#
    .SYNOPSIS
        Returns ordered predicates for the Command Log view mode filters.
    .DESCRIPTION
        Produces:
          - Status group: 'OK', 'Error' — keyed on the Succeeded property.
          - Command-type group: one entry per unique p4 subcommand extracted from
            CommandLine. Subcommand extracted via regex 'p4\s+(\S+)'.
            Unrecognised command lines are collected under an 'other' bucket.
        The result is an ordered hashtable so the filter pane renders in a
        consistent, predictable order.
    .OUTPUTS
        [ordered] hashtable  —  FilterName → [scriptblock]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [object[]]$CommandLog = @()
    )

    $result = [ordered]@{}

    if (@($CommandLog).Count -eq 0) {
        return $result
    }

    # Status filters
    $result['OK']    = { param($e) [bool]$e.Succeeded }.GetNewClosure()
    $result['Error'] = { param($e) -not [bool]$e.Succeeded }.GetNewClosure()

    # Duration-class filters (M1.3)
    $result['duration:info']     = { param($e) ([string]$e.DurationClass) -in @('Info', 'Warning', 'Critical') }.GetNewClosure()
    $result['duration:warning']  = { param($e) ([string]$e.DurationClass) -in @('Warning', 'Critical') }.GetNewClosure()
    $result['duration:critical'] = { param($e) ([string]$e.DurationClass) -eq 'Critical' }.GetNewClosure()

    # Collect unique subcommands
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $CommandLog) {
        $cmdLine = [string]$entry.CommandLine
        if ($cmdLine -match 'p4\s+(-\S+\s+)*(\S+)') {
            $sub = $Matches[2]
            if (-not [string]::IsNullOrWhiteSpace($sub) -and $sub -notmatch '^-') {
                [void]$seen.Add($sub.ToLower())
            }
        }
    }

    foreach ($sub in ($seen | Sort-Object)) {
        $subCopy = $sub  # capture for closure
        $result["cmd:$sub"] = { param($e) ([string]$e.CommandLine) -match ('p4(\s+-\S+)*\s+' + [regex]::Escape($subCopy) + '(\s|$)') }.GetNewClosure()
    }

    return $result
}

# Returns the ordered list of all filter names for the given view mode.
function Get-AllFilterNames {
    param(
        [Parameter(Mandatory = $false)]
        [string]$ViewMode = 'Pending',

        [Parameter(Mandatory = $false)]
        [string]$CurrentUser = ''
    )

    if ($ViewMode -eq 'Submitted') {
        return @((Get-SubmittedFilterPredicates -CurrentUser $CurrentUser).Keys)
    }
    if ($ViewMode -eq 'CommandLog') {
        return @()  # CommandLog filter names depend on dynamic data; computed in Update-CommandLogDerivedState
    }
    return @($script:PendingFilterPredicates.Keys)
}

# Tests whether a single entry passes a named filter predicate.
# Returns $false when the filter name is not in the registry.
function Test-EntryMatchesFilter {
    param(
        [Parameter(Mandatory = $true)][string]$FilterName,
        [Parameter(Mandatory = $true)][AllowNull()]$Entry,
        [Parameter(Mandatory = $false)][string]$ViewMode = 'Pending',
        [Parameter(Mandatory = $false)][string]$CurrentUser = ''
    )
    if ($null -eq $Entry) { return $false }

    if ($ViewMode -eq 'CommandLog') {
        $predicates = Get-CommandLogFilterPredicates -CommandLog @($Entry)
        $predicate  = $predicates[$FilterName]
        if ($null -eq $predicate) { return $false }
        return [bool](& $predicate $Entry)
    }

    if ($ViewMode -eq 'Submitted') {
        $predicates = Get-SubmittedFilterPredicates -CurrentUser $CurrentUser
        $predicate  = $predicates[$FilterName]
    } else {
        $predicate = $script:PendingFilterPredicates[$FilterName]
    }

    if ($null -eq $predicate) { return $false }
    return [bool](& $predicate $Entry)
}

function Get-VisibleChangeIds {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$AllChanges,
        [Parameter(Mandatory = $false)][AllowNull()]$SelectedFilters,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$SearchText = '',
        [Parameter(Mandatory = $false)][ValidateSet('None', 'Regex', 'Text')][string]$SearchMode = 'None',
        [Parameter(Mandatory = $false)][ValidateSet('Default', 'CapturedDesc')][string]$SortMode = 'Default',
        [Parameter(Mandatory = $false)][string]$ViewMode = 'Pending',
        [Parameter(Mandatory = $false)][string]$CurrentUser = ''
    )

    # CommandLog mode does not use changelist-based filtering
    if ($ViewMode -eq 'CommandLog') { return @() }

    $predicates = if ($ViewMode -eq 'Submitted') {
        Get-SubmittedFilterPredicates -CurrentUser $CurrentUser
    } else {
        $script:PendingFilterPredicates
    }

    $requiredFilters = @()
    if ($null -ne $SelectedFilters) {
        if ($SelectedFilters -is [System.Collections.IEnumerable] -and -not ($SelectedFilters -is [string])) {
            foreach ($filter in $SelectedFilters) {
                if (-not [string]::IsNullOrWhiteSpace([string]$filter)) {
                    $requiredFilters += [string]$filter
                }
            }
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$SelectedFilters)) {
            $requiredFilters = @([string]$SelectedFilters)
        }
    }

    $filtered = @($AllChanges | Where-Object {
        $entry = $_

        $matchesFilters = $true
        foreach ($requiredFilter in $requiredFilters) {
            $predicate = $predicates[$requiredFilter]
            if ($null -eq $predicate) { continue }   # unknown filter — skip
            if (-not [bool](& $predicate $entry)) {
                $matchesFilters = $false
                break
            }
        }
        if (-not $matchesFilters) {
            return $false
        }

        if ([string]::IsNullOrWhiteSpace($SearchText) -or $SearchMode -eq 'None') {
            return $true
        }

        $title = [string]$entry.Title
        switch ($SearchMode) {
            'Text' { return $title.IndexOf($SearchText, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 }
            'Regex' {
                try {
                    return [regex]::IsMatch($title, $SearchText)
                } catch {
                    return $true
                }
            }
            default { return $true }
        }
    })

    switch ($SortMode) {
        'CapturedDesc' {
            $filtered = @($filtered | Sort-Object @{ Expression = { if ($_.Captured -is [datetime]) { -$_.Captured.Ticks } else { [long]::MaxValue } } }, @{ Expression = { $_.Id } })
        }
        default {
            $filtered = @($filtered | Sort-Object Id)
        }
    }

    return @($filtered | ForEach-Object { $_.Id })
}

Export-ModuleMember -Function Get-AllFilterNames, Get-CommandLogFilterPredicates, Test-EntryMatchesFilter, Get-VisibleChangeIds
