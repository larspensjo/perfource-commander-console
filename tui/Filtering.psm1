Set-StrictMode -Version Latest

# Predicate registry: maps filter name → scriptblock($entry) → $true if entry passes the filter
$script:FilterPredicates = [ordered]@{
    'No shelved files' = { param($entry) -not [bool]$entry.HasShelvedFiles }
    'No opened files'   = { param($entry) -not [bool]$entry.HasOpenedFiles  }
}

# Returns the ordered list of all static filter names
function Get-AllFilterNames {
    return @($script:FilterPredicates.Keys)
}

# Tests whether a single entry passes a named filter predicate.
# Returns $false when the filter name is not in the registry.
function Test-EntryMatchesFilter {
    param(
        [Parameter(Mandatory = $true)][string]$FilterName,
        [Parameter(Mandatory = $true)][AllowNull()]$Entry
    )
    if ($null -eq $Entry) { return $false }
    $predicate = $script:FilterPredicates[$FilterName]
    if ($null -eq $predicate) { return $false }
    return [bool](& $predicate $Entry)
}

function Get-VisibleChangeIds {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$AllChanges,
        [Parameter(Mandatory = $false)][AllowNull()]$SelectedFilters,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$SearchText = '',
        [Parameter(Mandatory = $false)][ValidateSet('None', 'Regex', 'Text')][string]$SearchMode = 'None',
        [Parameter(Mandatory = $false)][ValidateSet('Default', 'CapturedDesc')][string]$SortMode = 'Default'
    )

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
            $predicate = $script:FilterPredicates[$requiredFilter]
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

Export-ModuleMember -Function Get-AllFilterNames, Test-EntryMatchesFilter, Get-VisibleChangeIds
