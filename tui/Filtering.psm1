Set-StrictMode -Version Latest

function Get-VisibleIdeaIds {
    param(
        [Parameter(Mandatory = $true)][object[]]$AllIdeas,
        [Parameter(Mandatory = $false)][AllowNull()]$SelectedTags,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$SearchText = '',
        [Parameter(Mandatory = $false)][ValidateSet('None', 'Regex', 'Text')][string]$SearchMode = 'None',
        [Parameter(Mandatory = $false)][ValidateSet('Default', 'Priority', 'Risk', 'CapturedDesc')][string]$SortMode = 'Default'
    )

    $requiredTags = @()
    if ($null -ne $SelectedTags) {
        if ($SelectedTags -is [System.Collections.IEnumerable] -and -not ($SelectedTags -is [string])) {
            foreach ($tag in $SelectedTags) {
                if (-not [string]::IsNullOrWhiteSpace([string]$tag)) {
                    $requiredTags += [string]$tag
                }
            }
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$SelectedTags)) {
            $requiredTags = @([string]$SelectedTags)
        }
    }

    $filtered = @($AllIdeas | Where-Object {
        $idea = $_

        $matchesTags = $true
        foreach ($requiredTag in $requiredTags) {
            if (-not (@($idea.Tags) -contains $requiredTag)) {
                $matchesTags = $false
                break
            }
        }
        if (-not $matchesTags) {
            return $false
        }

        if ([string]::IsNullOrWhiteSpace($SearchText) -or $SearchMode -eq 'None') {
            return $true
        }

        $title = [string]$idea.Title
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
        'Priority' {
            $rank = @{ P0 = 0; P1 = 1; P2 = 2; P3 = 3 }
            $filtered = @($filtered | Sort-Object -Stable @{ Expression = { if ($rank.ContainsKey($_.Priority)) { $rank[$_.Priority] } else { 99 } } }, @{ Expression = { $_.Id } })
        }
        'Risk' {
            $rank = @{ H = 0; M = 1; L = 2 }
            $filtered = @($filtered | Sort-Object -Stable @{ Expression = { if ($rank.ContainsKey($_.Risk)) { $rank[$_.Risk] } else { 99 } } }, @{ Expression = { $_.Id } })
        }
        'CapturedDesc' {
            $filtered = @($filtered | Sort-Object -Stable @{ Expression = { if ($_.Captured -is [datetime]) { -$_.Captured.Ticks } else { [long]::MaxValue } } }, @{ Expression = { $_.Id } })
        }
        default {
            $filtered = @($filtered | Sort-Object -Stable Id)
        }
    }

    return @($filtered | ForEach-Object { $_.Id })
}

Export-ModuleMember -Function Get-VisibleIdeaIds
