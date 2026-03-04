Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Filtering.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Layout.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\p4\P4Cli.psm1') -Force

function New-BrowserState {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Changes,
        [Parameter(Mandatory = $false)][int]$InitialWidth = 120,
        [Parameter(Mandatory = $false)][int]$InitialHeight = 40
    )

    $tags = @($Changes | ForEach-Object { @($_.Tags) } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)

    $state = [pscustomobject]@{
        Data = [pscustomobject]@{
            AllChanges    = @($Changes)
            AllTags       = @($tags)
            DescribeCache = @{}
        }
        Ui = [pscustomobject]@{
            ActivePane = 'Tags'
            IsMaximized = $false
            HideUnavailableTags = $false
            Layout = Get-BrowserLayout -Width $InitialWidth -Height $InitialHeight
        }
        Query = [pscustomobject]@{
            SelectedTags = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            SearchText = ''
            SearchMode = 'None'
            SortMode = 'Default'
        }
        Derived = [pscustomobject]@{
            VisibleChangeIds = @()
            VisibleTags = @()
        }
        Cursor = [pscustomobject]@{
            TagIndex = 0
            TagScrollTop = 0
            ChangeIndex = 0
            ChangeScrollTop = 0
        }
        Runtime = [pscustomobject]@{
            IsRunning      = $true
            LastError      = $null
            LastSelectedId = $null
        }
    }

    return Update-BrowserDerivedState -State $state
}

function Copy-BrowserState {
    param([Parameter(Mandatory = $true)]$State)

    $copy = [pscustomobject]@{
        Data = [pscustomobject]@{
            AllChanges    = @($State.Data.AllChanges)
            AllTags       = @($State.Data.AllTags)
            DescribeCache = $State.Data.DescribeCache          # shared reference (append-only)
        }
        Ui = [pscustomobject]@{
            ActivePane = $State.Ui.ActivePane
            IsMaximized = $State.Ui.IsMaximized
            HideUnavailableTags = $State.Ui.HideUnavailableTags
            Layout = $State.Ui.Layout
        }
        Query = [pscustomobject]@{
            SelectedTags = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            SearchText = $State.Query.SearchText
            SearchMode = $State.Query.SearchMode
            SortMode = $State.Query.SortMode
        }
        Derived = [pscustomobject]@{
            VisibleChangeIds = @($State.Derived.VisibleChangeIds)
            VisibleTags = @($State.Derived.VisibleTags)
        }
        Cursor = [pscustomobject]@{
            TagIndex = $State.Cursor.TagIndex
            TagScrollTop = $State.Cursor.TagScrollTop
            ChangeIndex = $State.Cursor.ChangeIndex
            ChangeScrollTop = $State.Cursor.ChangeScrollTop
        }
        Runtime = [pscustomobject]@{
            IsRunning      = $State.Runtime.IsRunning
            LastError      = $State.Runtime.LastError
            LastSelectedId = $State.Runtime.LastSelectedId
        }
    }

    foreach ($tag in $State.Query.SelectedTags) {
        [void]$copy.Query.SelectedTags.Add($tag)
    }

    return $copy
}

function Update-BrowserDerivedState {
    param([Parameter(Mandatory = $true)]$State)

    $visibleChangeIds = Get-VisibleChangeIds -AllChanges $State.Data.AllChanges -SelectedTags $State.Query.SelectedTags -SearchText $State.Query.SearchText -SearchMode $State.Query.SearchMode -SortMode $State.Query.SortMode
    $State.Derived.VisibleChangeIds = @($visibleChangeIds)

    $visibleChangeIdSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($id in $State.Derived.VisibleChangeIds) {
        [void]$visibleChangeIdSet.Add([string]$id)
    }

    $visibleChanges = @($State.Data.AllChanges | Where-Object { $visibleChangeIdSet.Contains([string]$_.Id) })

    $tagItems = New-Object System.Collections.Generic.List[object]
    foreach ($tag in $State.Data.AllTags) {
        $matchCount = 0
        foreach ($cl in $visibleChanges) {
            if (@($cl.Tags) -contains $tag) {
                $matchCount++
            }
        }

        $isSelected = $State.Query.SelectedTags.Contains($tag)
        $isSelectable = $isSelected -or ($matchCount -gt 0)

        $tagItems.Add([pscustomobject]@{
            Name = $tag
            MatchCount = $matchCount
            IsSelected = $isSelected
            IsSelectable = $isSelectable
        }) | Out-Null
    }

    $visibleTags = @($tagItems.ToArray())
    if ($State.Ui.HideUnavailableTags) {
        $visibleTags = @($visibleTags | Where-Object { $_.IsSelected -or $_.IsSelectable })
    }
    $State.Derived.VisibleTags = @($visibleTags)

    $visibleCount = $State.Derived.VisibleChangeIds.Count
    if ($visibleCount -eq 0) {
        $State.Cursor.ChangeIndex = 0
        $State.Cursor.ChangeScrollTop = 0
    } else {
        if ($State.Cursor.ChangeIndex -ge $visibleCount) {
            $State.Cursor.ChangeIndex = $visibleCount - 1
        }
        if ($State.Cursor.ChangeIndex -lt 0) {
            $State.Cursor.ChangeIndex = 0
        }
        if ($State.Cursor.ChangeScrollTop -lt 0) {
            $State.Cursor.ChangeScrollTop = 0
        }

        $changeViewport = 1
        if ($State.Ui.Layout -and $State.Ui.Layout.Mode -eq 'Normal') {
            $changeViewport = [Math]::Max(1, $State.Ui.Layout.ListPane.H - 1)
        }
        $maxChangeScroll = [Math]::Max(0, $visibleCount - $changeViewport)
        if ($State.Cursor.ChangeScrollTop -gt $maxChangeScroll) {
            $State.Cursor.ChangeScrollTop = $maxChangeScroll
        }
        if ($State.Cursor.ChangeIndex -lt $State.Cursor.ChangeScrollTop) {
            $State.Cursor.ChangeScrollTop = $State.Cursor.ChangeIndex
        }
        if ($State.Cursor.ChangeIndex -ge ($State.Cursor.ChangeScrollTop + $changeViewport)) {
            $State.Cursor.ChangeScrollTop = [Math]::Max(0, $State.Cursor.ChangeIndex - $changeViewport + 1)
        }
    }

    $tagViewport = 1
    if ($State.Ui.Layout -and $State.Ui.Layout.Mode -eq 'Normal') {
        $tagViewport = [Math]::Max(1, $State.Ui.Layout.TagPane.H - 2)
    }

    $tagCount = $State.Derived.VisibleTags.Count
    if ($tagCount -eq 0) {
        $State.Cursor.TagIndex = 0
        $State.Cursor.TagScrollTop = 0
    } else {
        if ($State.Cursor.TagIndex -lt 0) {
            $State.Cursor.TagIndex = 0
        }
        if ($State.Cursor.TagIndex -ge $tagCount) {
            $State.Cursor.TagIndex = $tagCount - 1
        }

        $maxTagScroll = [Math]::Max(0, $tagCount - $tagViewport)
        if ($State.Cursor.TagScrollTop -gt $maxTagScroll) {
            $State.Cursor.TagScrollTop = $maxTagScroll
        }
        if ($State.Cursor.TagScrollTop -lt 0) {
            $State.Cursor.TagScrollTop = 0
        }
        if ($State.Cursor.TagIndex -lt $State.Cursor.TagScrollTop) {
            $State.Cursor.TagScrollTop = $State.Cursor.TagIndex
        }
        if ($State.Cursor.TagIndex -ge ($State.Cursor.TagScrollTop + $tagViewport)) {
            $State.Cursor.TagScrollTop = [Math]::Max(0, $State.Cursor.TagIndex - $tagViewport + 1)
        }
    }

    return $State
}

function Invoke-BrowserReducer {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$Action
    )

    $next = Copy-BrowserState -State $State

    function Get-TagViewportSize {
        param($CurrentState)
        if ($CurrentState.Ui.Layout -and $CurrentState.Ui.Layout.Mode -eq 'Normal') {
            return [Math]::Max(1, $CurrentState.Ui.Layout.TagPane.H - 2)
        }
        return 1
    }

    function Get-ChangeViewportSize {
        param($CurrentState)
        if ($CurrentState.Ui.Layout -and $CurrentState.Ui.Layout.Mode -eq 'Normal') {
            return [Math]::Max(1, $CurrentState.Ui.Layout.ListPane.H - 1)
        }
        return 1
    }

    switch ($Action.Type) {
        'Quit' {
            $next.Runtime.IsRunning = $false
            return $next
        }
        'SwitchPane' {
            if ($next.Ui.ActivePane -eq 'Tags') {
                $next.Ui.ActivePane = 'Changelists'
            } else {
                $next.Ui.ActivePane = 'Tags'
            }
            return $next
        }
        'MoveUp' {
            if ($next.Ui.ActivePane -eq 'Tags') {
                if ($next.Cursor.TagIndex -gt 0) { $next.Cursor.TagIndex-- }
            } else {
                if ($next.Cursor.ChangeIndex -gt 0) { $next.Cursor.ChangeIndex-- }
            }
            return Update-BrowserDerivedState -State $next
        }
        'MoveDown' {
            if ($next.Ui.ActivePane -eq 'Tags') {
                $maxTagIndex = [Math]::Max(0, $next.Derived.VisibleTags.Count - 1)
                if ($next.Cursor.TagIndex -lt $maxTagIndex) { $next.Cursor.TagIndex++ }
            } else {
                $maxChangeIndex = [Math]::Max(0, $next.Derived.VisibleChangeIds.Count - 1)
                if ($next.Cursor.ChangeIndex -lt $maxChangeIndex) { $next.Cursor.ChangeIndex++ }
            }
            return Update-BrowserDerivedState -State $next
        }
        'PageUp' {
            if ($next.Ui.ActivePane -eq 'Tags') {
                $step = Get-TagViewportSize -CurrentState $next
                $next.Cursor.TagIndex = [Math]::Max(0, $next.Cursor.TagIndex - $step)
            } else {
                $step = Get-ChangeViewportSize -CurrentState $next
                $next.Cursor.ChangeIndex = [Math]::Max(0, $next.Cursor.ChangeIndex - $step)
            }
            return Update-BrowserDerivedState -State $next
        }
        'PageDown' {
            if ($next.Ui.ActivePane -eq 'Tags') {
                $step = Get-TagViewportSize -CurrentState $next
                $maxTagIndex = [Math]::Max(0, $next.Derived.VisibleTags.Count - 1)
                $next.Cursor.TagIndex = [Math]::Min($maxTagIndex, $next.Cursor.TagIndex + $step)
            } else {
                $step = Get-ChangeViewportSize -CurrentState $next
                $maxChangeIndex = [Math]::Max(0, $next.Derived.VisibleChangeIds.Count - 1)
                $next.Cursor.ChangeIndex = [Math]::Min($maxChangeIndex, $next.Cursor.ChangeIndex + $step)
            }
            return Update-BrowserDerivedState -State $next
        }
        'MoveHome' {
            if ($next.Ui.ActivePane -eq 'Tags') {
                $next.Cursor.TagIndex = 0
                $next.Cursor.TagScrollTop = 0
            } else {
                $next.Cursor.ChangeIndex = 0
                $next.Cursor.ChangeScrollTop = 0
            }
            return Update-BrowserDerivedState -State $next
        }
        'MoveEnd' {
            if ($next.Ui.ActivePane -eq 'Tags') {
                $next.Cursor.TagIndex = [Math]::Max(0, $next.Derived.VisibleTags.Count - 1)
            } else {
                $next.Cursor.ChangeIndex = [Math]::Max(0, $next.Derived.VisibleChangeIds.Count - 1)
            }
            return Update-BrowserDerivedState -State $next
        }
        'ToggleTag' {
            $tag = $null
            $tagProp = $Action.PSObject.Properties['Tag']
            if ($null -ne $tagProp) {
                $tag = [string]$tagProp.Value
            }
            if ([string]::IsNullOrWhiteSpace($tag)) {
                if ($next.Derived.VisibleTags.Count -eq 0) {
                    return $next
                }
                $tag = [string]$next.Derived.VisibleTags[$next.Cursor.TagIndex].Name
            }

            if ($next.Query.SelectedTags.Contains($tag)) {
                [void]$next.Query.SelectedTags.Remove($tag)
            } else {
                [void]$next.Query.SelectedTags.Add($tag)
            }

            $next.Cursor.ChangeIndex = 0
            $next.Cursor.ChangeScrollTop = 0
            $next = Update-BrowserDerivedState -State $next

            $targetTagIndex = -1
            for ($i = 0; $i -lt $next.Derived.VisibleTags.Count; $i++) {
                if ($next.Derived.VisibleTags[$i].Name -eq $tag) {
                    $targetTagIndex = $i
                    break
                }
            }
            if ($targetTagIndex -ge 0) {
                $next.Cursor.TagIndex = $targetTagIndex
            }

            return Update-BrowserDerivedState -State $next
        }
        'ToggleHideUnavailableTags' {
            $currentTagName = $null
            if ($next.Cursor.TagIndex -ge 0 -and $next.Cursor.TagIndex -lt $next.Derived.VisibleTags.Count) {
                $currentTagName = [string]$next.Derived.VisibleTags[$next.Cursor.TagIndex].Name
            }

            $next.Ui.HideUnavailableTags = -not $next.Ui.HideUnavailableTags
            $next.Cursor.TagIndex = 0
            $next.Cursor.TagScrollTop = 0
            $next = Update-BrowserDerivedState -State $next

            if (-not [string]::IsNullOrWhiteSpace($currentTagName)) {
                for ($i = 0; $i -lt $next.Derived.VisibleTags.Count; $i++) {
                    if ($next.Derived.VisibleTags[$i].Name -eq $currentTagName) {
                        $next.Cursor.TagIndex = $i
                        break
                    }
                }
            }

            return Update-BrowserDerivedState -State $next
        }
        'Describe' {
            if ($next.Derived.VisibleChangeIds.Count -eq 0) { return $next }
            $idx = [Math]::Max(0, [Math]::Min($next.Cursor.ChangeIndex,
                                               $next.Derived.VisibleChangeIds.Count - 1))
            $next.Runtime.LastSelectedId = $next.Derived.VisibleChangeIds[$idx]
            return Update-BrowserDerivedState -State $next
        }
        'Reload' {
            $next.Data.DescribeCache = @{}
            $next.Runtime.LastSelectedId = $null
            try {
                $fresh = Get-P4ChangelistEntries -Max 200
                $next.Data.AllChanges = @($fresh)
                $next.Data.AllTags = @(
                    $next.Data.AllChanges |
                        ForEach-Object { @($_.Tags) } |
                        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
                        Sort-Object -Unique
                )
                $next.Runtime.LastError = $null
            }
            catch {
                $next.Runtime.LastError = $_.Exception.Message
            }

            return Update-BrowserDerivedState -State $next
        }
        'Resize' {
            $width = [int]$Action.Width
            $height = [int]$Action.Height
            if ($width -gt 10 -and $height -gt 5) {
                $next.Ui.Layout = Get-BrowserLayout -Width $width -Height $height
            }
            return Update-BrowserDerivedState -State $next
        }
        default {
            return Update-BrowserDerivedState -State $next
        }
    }
}

function ConvertTo-ChangeNumberFromId {
    param([string]$Id)
    if ($Id -match '^CL-(\d+)$') { return [int]$Matches[1] }
    return $null
}

Export-ModuleMember -Function New-BrowserState, Copy-BrowserState, Invoke-BrowserReducer, Update-BrowserDerivedState, ConvertTo-ChangeNumberFromId
