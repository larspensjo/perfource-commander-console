Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Filtering.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Layout.psm1') -Force

function New-BrowserState {
    param(
        [Parameter(Mandatory = $true)][object[]]$Ideas,
        [Parameter(Mandatory = $false)][int]$InitialWidth = 120,
        [Parameter(Mandatory = $false)][int]$InitialHeight = 40
    )

    $tags = @($Ideas | ForEach-Object { @($_.Tags) } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)

    $state = [pscustomobject]@{
        Data = [pscustomobject]@{
            AllIdeas = @($Ideas)
            AllTags = @($tags)
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
            VisibleIdeaIds = @()
            VisibleTags = @()
        }
        Cursor = [pscustomobject]@{
            TagIndex = 0
            TagScrollTop = 0
            IdeaIndex = 0
            IdeaScrollTop = 0
        }
        Runtime = [pscustomobject]@{
            IsRunning = $true
            LastError = $null
        }
    }

    return Update-BrowserDerivedState -State $state
}

function Copy-BrowserState {
    param([Parameter(Mandatory = $true)]$State)

    $copy = [pscustomobject]@{
        Data = [pscustomobject]@{
            AllIdeas = @($State.Data.AllIdeas)
            AllTags = @($State.Data.AllTags)
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
            VisibleIdeaIds = @($State.Derived.VisibleIdeaIds)
            VisibleTags = @($State.Derived.VisibleTags)
        }
        Cursor = [pscustomobject]@{
            TagIndex = $State.Cursor.TagIndex
            TagScrollTop = $State.Cursor.TagScrollTop
            IdeaIndex = $State.Cursor.IdeaIndex
            IdeaScrollTop = $State.Cursor.IdeaScrollTop
        }
        Runtime = [pscustomobject]@{
            IsRunning = $State.Runtime.IsRunning
            LastError = $State.Runtime.LastError
        }
    }

    foreach ($tag in $State.Query.SelectedTags) {
        [void]$copy.Query.SelectedTags.Add($tag)
    }

    return $copy
}

function Update-BrowserDerivedState {
    param([Parameter(Mandatory = $true)]$State)

    $visibleIdeaIds = Get-VisibleIdeaIds -AllIdeas $State.Data.AllIdeas -SelectedTags $State.Query.SelectedTags -SearchText $State.Query.SearchText -SearchMode $State.Query.SearchMode -SortMode $State.Query.SortMode
    $State.Derived.VisibleIdeaIds = @($visibleIdeaIds)

    $visibleIdeaIdSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($id in $State.Derived.VisibleIdeaIds) {
        [void]$visibleIdeaIdSet.Add([string]$id)
    }

    $visibleIdeas = @($State.Data.AllIdeas | Where-Object { $visibleIdeaIdSet.Contains([string]$_.Id) })

    $tagItems = New-Object System.Collections.Generic.List[object]
    foreach ($tag in $State.Data.AllTags) {
        $matchCount = 0
        foreach ($idea in $visibleIdeas) {
            if (@($idea.Tags) -contains $tag) {
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

    $visibleCount = $State.Derived.VisibleIdeaIds.Count
    if ($visibleCount -eq 0) {
        $State.Cursor.IdeaIndex = 0
        $State.Cursor.IdeaScrollTop = 0
    } else {
        if ($State.Cursor.IdeaIndex -ge $visibleCount) {
            $State.Cursor.IdeaIndex = $visibleCount - 1
        }
        if ($State.Cursor.IdeaIndex -lt 0) {
            $State.Cursor.IdeaIndex = 0
        }
        if ($State.Cursor.IdeaScrollTop -lt 0) {
            $State.Cursor.IdeaScrollTop = 0
        }

        $ideaViewport = 1
        if ($State.Ui.Layout -and $State.Ui.Layout.Mode -eq 'Normal') {
            $ideaViewport = [Math]::Max(1, $State.Ui.Layout.ListPane.H - 1)
        }
        $maxIdeaScroll = [Math]::Max(0, $visibleCount - $ideaViewport)
        if ($State.Cursor.IdeaScrollTop -gt $maxIdeaScroll) {
            $State.Cursor.IdeaScrollTop = $maxIdeaScroll
        }
        if ($State.Cursor.IdeaIndex -lt $State.Cursor.IdeaScrollTop) {
            $State.Cursor.IdeaScrollTop = $State.Cursor.IdeaIndex
        }
        if ($State.Cursor.IdeaIndex -ge ($State.Cursor.IdeaScrollTop + $ideaViewport)) {
            $State.Cursor.IdeaScrollTop = [Math]::Max(0, $State.Cursor.IdeaIndex - $ideaViewport + 1)
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

    function Get-IdeaViewportSize {
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
                $next.Ui.ActivePane = 'Ideas'
            } else {
                $next.Ui.ActivePane = 'Tags'
            }
            return $next
        }
        'MoveUp' {
            if ($next.Ui.ActivePane -eq 'Tags') {
                if ($next.Cursor.TagIndex -gt 0) { $next.Cursor.TagIndex-- }
            } else {
                if ($next.Cursor.IdeaIndex -gt 0) { $next.Cursor.IdeaIndex-- }
            }
            return Update-BrowserDerivedState -State $next
        }
        'MoveDown' {
            if ($next.Ui.ActivePane -eq 'Tags') {
                $maxTagIndex = [Math]::Max(0, $next.Derived.VisibleTags.Count - 1)
                if ($next.Cursor.TagIndex -lt $maxTagIndex) { $next.Cursor.TagIndex++ }
            } else {
                $maxIdeaIndex = [Math]::Max(0, $next.Derived.VisibleIdeaIds.Count - 1)
                if ($next.Cursor.IdeaIndex -lt $maxIdeaIndex) { $next.Cursor.IdeaIndex++ }
            }
            return Update-BrowserDerivedState -State $next
        }
        'PageUp' {
            if ($next.Ui.ActivePane -eq 'Tags') {
                $step = Get-TagViewportSize -CurrentState $next
                $next.Cursor.TagIndex = [Math]::Max(0, $next.Cursor.TagIndex - $step)
            } else {
                $step = Get-IdeaViewportSize -CurrentState $next
                $next.Cursor.IdeaIndex = [Math]::Max(0, $next.Cursor.IdeaIndex - $step)
            }
            return Update-BrowserDerivedState -State $next
        }
        'PageDown' {
            if ($next.Ui.ActivePane -eq 'Tags') {
                $step = Get-TagViewportSize -CurrentState $next
                $maxTagIndex = [Math]::Max(0, $next.Derived.VisibleTags.Count - 1)
                $next.Cursor.TagIndex = [Math]::Min($maxTagIndex, $next.Cursor.TagIndex + $step)
            } else {
                $step = Get-IdeaViewportSize -CurrentState $next
                $maxIdeaIndex = [Math]::Max(0, $next.Derived.VisibleIdeaIds.Count - 1)
                $next.Cursor.IdeaIndex = [Math]::Min($maxIdeaIndex, $next.Cursor.IdeaIndex + $step)
            }
            return Update-BrowserDerivedState -State $next
        }
        'MoveHome' {
            if ($next.Ui.ActivePane -eq 'Tags') {
                $next.Cursor.TagIndex = 0
                $next.Cursor.TagScrollTop = 0
            } else {
                $next.Cursor.IdeaIndex = 0
                $next.Cursor.IdeaScrollTop = 0
            }
            return Update-BrowserDerivedState -State $next
        }
        'MoveEnd' {
            if ($next.Ui.ActivePane -eq 'Tags') {
                $next.Cursor.TagIndex = [Math]::Max(0, $next.Derived.VisibleTags.Count - 1)
            } else {
                $next.Cursor.IdeaIndex = [Math]::Max(0, $next.Derived.VisibleIdeaIds.Count - 1)
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

            $next.Cursor.IdeaIndex = 0
            $next.Cursor.IdeaScrollTop = 0
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

Export-ModuleMember -Function New-BrowserState, Invoke-BrowserReducer, Update-BrowserDerivedState
