Set-StrictMode -Version Latest

$script:CommandHistoryMaxSize = 50

Import-Module (Join-Path $PSScriptRoot 'Filtering.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Layout.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\p4\P4Cli.psm1') -Force

# ── Changelist viewport geometry helpers ──────────────────────────────────────
# These must stay in sync with the render logic in Render.psm1 (which uses H-2).

function Get-ChangeInnerViewRows {
    param($State)
    if ($null -ne $State.Ui.Layout -and $State.Ui.Layout.Mode -eq 'Normal') {
        return [Math]::Max(1, $State.Ui.Layout.ListPane.H - 2)
    }
    return 1
}

function Get-ChangeRowsPerItem {
    param($State)
    $expanded = $false
    if ($null -ne $State.Ui -and ($State.Ui.PSObject.Properties.Match('ExpandedChangelists')).Count -gt 0) {
        $expanded = [bool]$State.Ui.ExpandedChangelists
    }
    if ($expanded) {
        $innerRows = Get-ChangeInnerViewRows -State $State
        if ($innerRows -ge 2) { return 2 }
    }
    return 1
}

function Get-ChangeViewCapacity {
    param($State)
    $innerRows   = Get-ChangeInnerViewRows -State $State
    $rowsPerItem = Get-ChangeRowsPerItem   -State $State
    return [Math]::Max(1, [Math]::Floor($innerRows / $rowsPerItem))
}
# ──────────────────────────────────────────────────────────────────────────────

function New-BrowserState {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Changes,
        [Parameter(Mandatory = $false)][int]$InitialWidth = 120,
        [Parameter(Mandatory = $false)][int]$InitialHeight = 40
    )

    $state = [pscustomobject]@{
        Data = [pscustomobject]@{
            AllChanges        = @($Changes)
            AllFilters        = @(Get-AllFilterNames -ViewMode 'Pending')
            DescribeCache     = @{}
            CurrentUser       = ''
            SubmittedChanges  = @()
            SubmittedHasMore  = $true
            SubmittedOldestId = $null
        }
        Ui = [pscustomobject]@{
            ActivePane             = 'Filters'
            IsMaximized            = $false
            HideUnavailableFilters = $false
            ExpandedChangelists    = $false
            ViewMode               = 'Pending'
            Layout                 = Get-BrowserLayout -Width $InitialWidth -Height $InitialHeight
        }
        Query = [pscustomobject]@{
            SelectedFilters = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            SearchText = ''
            SearchMode = 'None'
            SortMode = 'Default'
        }
        Derived = [pscustomobject]@{
            VisibleChangeIds = @()
            VisibleFilters = @()
        }
        Cursor = [pscustomobject]@{
            FilterIndex     = 0
            FilterScrollTop = 0
            ChangeIndex     = 0
            ChangeScrollTop = 0
            ViewSnapshots   = @{
                Pending   = @{ ChangeIndex = 0; ChangeScrollTop = 0 }
                Submitted = @{ ChangeIndex = 0; ChangeScrollTop = 0 }
            }
        }
        Runtime = [pscustomobject]@{
            IsRunning                = $true
            LastError                = $null
            LastSelectedId           = $null
            DetailChangeId           = $null
            DeleteChangeId           = $null
            ReloadRequested          = $false
            SubmittedReloadRequested = $false
            LoadMoreRequested        = $false
            ConfiguredMax            = 200
            HelpOverlayOpen          = $false
            CommandModal             = [pscustomobject]@{
                IsOpen         = $false
                IsBusy         = $false
                CurrentCommand = ''
                History        = @()
            }
        }
    }

    return Update-BrowserDerivedState -State $state
}

function Copy-BrowserState {
    param([Parameter(Mandatory = $true)]$State)

    # Deep-copy ViewSnapshots
    $viewSnapshotsCopy = @{}
    if (($State.Cursor.PSObject.Properties.Match('ViewSnapshots')).Count -gt 0 -and $null -ne $State.Cursor.ViewSnapshots) {
        foreach ($key in $State.Cursor.ViewSnapshots.Keys) {
            $snap = $State.Cursor.ViewSnapshots[$key]
            $viewSnapshotsCopy[$key] = @{
                ChangeIndex     = [int]$snap.ChangeIndex
                ChangeScrollTop = [int]$snap.ChangeScrollTop
            }
        }
    }

    $copy = [pscustomobject]@{
        Data = [pscustomobject]@{
            AllChanges        = @($State.Data.AllChanges)
            AllFilters        = @($State.Data.AllFilters)
            DescribeCache     = $State.Data.DescribeCache          # shared reference (append-only)
            CurrentUser       = if (($State.Data.PSObject.Properties.Match('CurrentUser')).Count -gt 0) { [string]$State.Data.CurrentUser } else { '' }
            SubmittedChanges  = if (($State.Data.PSObject.Properties.Match('SubmittedChanges')).Count -gt 0) { @($State.Data.SubmittedChanges) } else { @() }
            SubmittedHasMore  = if (($State.Data.PSObject.Properties.Match('SubmittedHasMore')).Count -gt 0) { [bool]$State.Data.SubmittedHasMore } else { $true }
            SubmittedOldestId = if (($State.Data.PSObject.Properties.Match('SubmittedOldestId')).Count -gt 0) { $State.Data.SubmittedOldestId } else { $null }
        }
        Ui = [pscustomobject]@{
            ActivePane             = $State.Ui.ActivePane
            IsMaximized            = $State.Ui.IsMaximized
            HideUnavailableFilters = $State.Ui.HideUnavailableFilters
            ExpandedChangelists    = if (($State.Ui.PSObject.Properties.Match('ExpandedChangelists')).Count -gt 0) { [bool]$State.Ui.ExpandedChangelists } else { $false }
            ViewMode               = if (($State.Ui.PSObject.Properties.Match('ViewMode')).Count -gt 0) { [string]$State.Ui.ViewMode } else { 'Pending' }
            Layout                 = $State.Ui.Layout
        }
        Query = [pscustomobject]@{
            SelectedFilters = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            SearchText = $State.Query.SearchText
            SearchMode = $State.Query.SearchMode
            SortMode = $State.Query.SortMode
        }
        Derived = [pscustomobject]@{
            VisibleChangeIds = @($State.Derived.VisibleChangeIds)
            VisibleFilters = @($State.Derived.VisibleFilters)
        }
        Cursor = [pscustomobject]@{
            FilterIndex     = $State.Cursor.FilterIndex
            FilterScrollTop = $State.Cursor.FilterScrollTop
            ChangeIndex     = $State.Cursor.ChangeIndex
            ChangeScrollTop = $State.Cursor.ChangeScrollTop
            ViewSnapshots   = $viewSnapshotsCopy
        }
        Runtime = [pscustomobject]@{
            IsRunning                = $State.Runtime.IsRunning
            LastError                = $State.Runtime.LastError
            LastSelectedId           = $State.Runtime.LastSelectedId
            DetailChangeId           = if (($State.Runtime.PSObject.Properties.Match('DetailChangeId')).Count -gt 0) { $State.Runtime.DetailChangeId } else { $null }
            DeleteChangeId           = $State.Runtime.DeleteChangeId
            ReloadRequested          = $State.Runtime.ReloadRequested
            SubmittedReloadRequested = if (($State.Runtime.PSObject.Properties.Match('SubmittedReloadRequested')).Count -gt 0) { [bool]$State.Runtime.SubmittedReloadRequested } else { $false }
            LoadMoreRequested        = if (($State.Runtime.PSObject.Properties.Match('LoadMoreRequested')).Count -gt 0) { [bool]$State.Runtime.LoadMoreRequested } else { $false }
            ConfiguredMax            = if (($State.Runtime.PSObject.Properties.Match('ConfiguredMax')).Count -gt 0) { [int]$State.Runtime.ConfiguredMax } else { 200 }
            HelpOverlayOpen          = if (($State.Runtime.PSObject.Properties.Match('HelpOverlayOpen')).Count -gt 0) { [bool]$State.Runtime.HelpOverlayOpen } else { $false }
            CommandModal             = [pscustomobject]@{
                IsOpen         = $State.Runtime.CommandModal.IsOpen
                IsBusy         = $State.Runtime.CommandModal.IsBusy
                CurrentCommand = $State.Runtime.CommandModal.CurrentCommand
                History        = @($State.Runtime.CommandModal.History)
            }
        }
    }

    foreach ($filter in $State.Query.SelectedFilters) {
        [void]$copy.Query.SelectedFilters.Add($filter)
    }

    return $copy
}

function Update-BrowserDerivedState {
    param([Parameter(Mandatory = $true)]$State)

    # Determine active source list and view context
    $viewMode    = if (($State.Ui.PSObject.Properties.Match('ViewMode')).Count -gt 0) { [string]$State.Ui.ViewMode } else { 'Pending' }
    $currentUser = if (($State.Data.PSObject.Properties.Match('CurrentUser')).Count -gt 0) { [string]$State.Data.CurrentUser } else { '' }

    # IMPORTANT: do NOT use if/else expression for @()-valued branches — PowerShell swallows
    # empty-array pipeline output and the variable becomes $null, failing [AllowEmptyCollection()].
    [object[]]$activeChanges = @()
    if ($viewMode -eq 'Submitted') {
        if (($State.Data.PSObject.Properties.Match('SubmittedChanges')).Count -gt 0 -and $null -ne $State.Data.SubmittedChanges) {
            $activeChanges = @($State.Data.SubmittedChanges)
        }
    } else {
        $activeChanges = @($State.Data.AllChanges)
    }

    # Regenerate AllFilters for the active view mode
    $State.Data.AllFilters = @(Get-AllFilterNames -ViewMode $viewMode -CurrentUser $currentUser)

    $visibleChangeIds = Get-VisibleChangeIds `
        -AllChanges $activeChanges `
        -SelectedFilters $State.Query.SelectedFilters `
        -SearchText $State.Query.SearchText `
        -SearchMode $State.Query.SearchMode `
        -SortMode $State.Query.SortMode `
        -ViewMode $viewMode `
        -CurrentUser $currentUser
    $State.Derived.VisibleChangeIds = @($visibleChangeIds)

    $visibleChangeIdSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($id in $State.Derived.VisibleChangeIds) {
        [void]$visibleChangeIdSet.Add([string]$id)
    }

    $visibleChanges = @($activeChanges | Where-Object { $visibleChangeIdSet.Contains([string]$_.Id) })

    $filterItems = New-Object System.Collections.Generic.List[object]
    foreach ($filter in $State.Data.AllFilters) {
        $matchCount = 0
        foreach ($cl in $visibleChanges) {
            if (Test-EntryMatchesFilter -FilterName $filter -Entry $cl -ViewMode $viewMode -CurrentUser $currentUser) {
                $matchCount++
            }
        }

        $isSelected   = $State.Query.SelectedFilters.Contains($filter)
        $isSelectable = $isSelected -or ($matchCount -gt 0)

        $filterItems.Add([pscustomobject]@{
            Name        = $filter
            MatchCount  = $matchCount
            IsSelected  = $isSelected
            IsSelectable = $isSelectable
        }) | Out-Null
    }

    $VisibleFilters = @($filterItems.ToArray())
    if ($State.Ui.HideUnavailableFilters) {
        $VisibleFilters = @($VisibleFilters | Where-Object { $_.IsSelected -or $_.IsSelectable })
    }
    $State.Derived.VisibleFilters = @($VisibleFilters)

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

        $changeViewport = Get-ChangeViewCapacity -State $State
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

    $filterViewport = 1
    if ($State.Ui.Layout -and $State.Ui.Layout.Mode -eq 'Normal') {
        $filterViewport = [Math]::Max(1, $State.Ui.Layout.FilterPane.H - 2)
    }

    $filterCount = $State.Derived.VisibleFilters.Count
    if ($filterCount -eq 0) {
        $State.Cursor.FilterIndex = 0
        $State.Cursor.FilterScrollTop = 0
    } else {
        if ($State.Cursor.FilterIndex -lt 0) {
            $State.Cursor.FilterIndex = 0
        }
        if ($State.Cursor.FilterIndex -ge $filterCount) {
            $State.Cursor.FilterIndex = $filterCount - 1
        }

        $maxFilterScroll = [Math]::Max(0, $filterCount - $filterViewport)
        if ($State.Cursor.FilterScrollTop -gt $maxFilterScroll) {
            $State.Cursor.FilterScrollTop = $maxFilterScroll
        }
        if ($State.Cursor.FilterScrollTop -lt 0) {
            $State.Cursor.FilterScrollTop = 0
        }
        if ($State.Cursor.FilterIndex -lt $State.Cursor.FilterScrollTop) {
            $State.Cursor.FilterScrollTop = $State.Cursor.FilterIndex
        }
        if ($State.Cursor.FilterIndex -ge ($State.Cursor.FilterScrollTop + $filterViewport)) {
            $State.Cursor.FilterScrollTop = [Math]::Max(0, $State.Cursor.FilterIndex - $filterViewport + 1)
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

    function Get-FilterViewportSize {
        param($CurrentState)
        if ($CurrentState.Ui.Layout -and $CurrentState.Ui.Layout.Mode -eq 'Normal') {
            return [Math]::Max(1, $CurrentState.Ui.Layout.FilterPane.H - 2)
        }
        return 1
    }

    function Get-ChangeViewportSize {
        param($CurrentState)
        return Get-ChangeViewCapacity -State $CurrentState
    }

    switch ($Action.Type) {
        'CommandStart' {
            $next.Runtime.CommandModal.IsBusy         = $true
            $next.Runtime.CommandModal.IsOpen         = $true
            $next.Runtime.CommandModal.CurrentCommand = [string]$Action.CommandLine
            return $next
        }
        'CommandFinish' {
            $startedAt  = [datetime]$Action.StartedAt
            $endedAt    = [datetime]$Action.EndedAt
            $durationMs = [int](($endedAt - $startedAt).TotalMilliseconds)
            $succeeded  = [bool]$Action.Succeeded
            $historyItem = [pscustomobject]@{
                StartedAt   = $startedAt
                EndedAt     = $endedAt
                CommandLine = [string]$Action.CommandLine
                ExitCode    = [int]$Action.ExitCode
                Succeeded   = $succeeded
                ErrorText   = [string]$Action.ErrorText
                DurationMs  = $durationMs
            }
            $trimmed = @($historyItem) + @($next.Runtime.CommandModal.History |
                Select-Object -First ($script:CommandHistoryMaxSize - 1))
            $next.Runtime.CommandModal.History        = $trimmed
            $next.Runtime.CommandModal.IsBusy         = $false
            $next.Runtime.CommandModal.CurrentCommand = ''
            if ($succeeded) {
                $next.Runtime.CommandModal.IsOpen = $false
            }
            return $next
        }
        'ShowCommandModal' {
            $next.Runtime.CommandModal.IsOpen = $true
            return $next
        }
        'ToggleCommandModal' {
            if (-not $next.Runtime.CommandModal.IsBusy) {
                $next.Runtime.CommandModal.IsOpen = -not $next.Runtime.CommandModal.IsOpen
            }
            return $next
        }
        'HideCommandModal' {
            # Escape: close help overlay first; then close command modal on second press
            if ($next.Runtime.HelpOverlayOpen) {
                $next.Runtime.HelpOverlayOpen = $false
                return $next
            }
            if (-not $next.Runtime.CommandModal.IsBusy) {
                $next.Runtime.CommandModal.IsOpen = $false
            }
            return $next
        }
        'ToggleHelpOverlay' {
            $next.Runtime.HelpOverlayOpen = -not $next.Runtime.HelpOverlayOpen
            return $next
        }
        'HideHelpOverlay' {
            $next.Runtime.HelpOverlayOpen = $false
            return $next
        }
        'Quit' {
            $next.Runtime.IsRunning = $false
            return $next
        }
        'SwitchPane' {
            if ($next.Ui.ActivePane -eq 'Filters') {
                $next.Ui.ActivePane = 'Changelists'
            } else {
                $next.Ui.ActivePane = 'Filters'
            }
            return $next
        }
        'MoveUp' {
            if ($next.Ui.ActivePane -eq 'Filters') {
                if ($next.Cursor.FilterIndex -gt 0) { $next.Cursor.FilterIndex-- }
            } else {
                if ($next.Cursor.ChangeIndex -gt 0) { $next.Cursor.ChangeIndex-- }
            }
            return Update-BrowserDerivedState -State $next
        }
        'MoveDown' {
            if ($next.Ui.ActivePane -eq 'Filters') {
                $maxFilterIndex = [Math]::Max(0, $next.Derived.VisibleFilters.Count - 1)
                if ($next.Cursor.FilterIndex -lt $maxFilterIndex) { $next.Cursor.FilterIndex++ }
            } else {
                $maxChangeIndex = [Math]::Max(0, $next.Derived.VisibleChangeIds.Count - 1)
                if ($next.Cursor.ChangeIndex -lt $maxChangeIndex) { $next.Cursor.ChangeIndex++ }
            }
            return Update-BrowserDerivedState -State $next
        }
        'PageUp' {
            if ($next.Ui.ActivePane -eq 'Filters') {
                $step = Get-FilterViewportSize -CurrentState $next
                $next.Cursor.FilterIndex = [Math]::Max(0, $next.Cursor.FilterIndex - $step)
            } else {
                $step = Get-ChangeViewportSize -CurrentState $next
                $next.Cursor.ChangeIndex = [Math]::Max(0, $next.Cursor.ChangeIndex - $step)
            }
            return Update-BrowserDerivedState -State $next
        }
        'PageDown' {
            if ($next.Ui.ActivePane -eq 'Filters') {
                $step = Get-FilterViewportSize -CurrentState $next
                $maxFilterIndex = [Math]::Max(0, $next.Derived.VisibleFilters.Count - 1)
                $next.Cursor.FilterIndex = [Math]::Min($maxFilterIndex, $next.Cursor.FilterIndex + $step)
            } else {
                $step = Get-ChangeViewportSize -CurrentState $next
                $maxChangeIndex = [Math]::Max(0, $next.Derived.VisibleChangeIds.Count - 1)
                $next.Cursor.ChangeIndex = [Math]::Min($maxChangeIndex, $next.Cursor.ChangeIndex + $step)
            }
            return Update-BrowserDerivedState -State $next
        }
        'MoveHome' {
            if ($next.Ui.ActivePane -eq 'Filters') {
                $next.Cursor.FilterIndex = 0
                $next.Cursor.FilterScrollTop = 0
            } else {
                $next.Cursor.ChangeIndex = 0
                $next.Cursor.ChangeScrollTop = 0
            }
            return Update-BrowserDerivedState -State $next
        }
        'MoveEnd' {
            if ($next.Ui.ActivePane -eq 'Filters') {
                $next.Cursor.FilterIndex = [Math]::Max(0, $next.Derived.VisibleFilters.Count - 1)
            } else {
                $next.Cursor.ChangeIndex = [Math]::Max(0, $next.Derived.VisibleChangeIds.Count - 1)
            }
            return Update-BrowserDerivedState -State $next
        }
        'ToggleFilter' {
            $filter = $null
            $tagProp = $Action.PSObject.Properties['Filter']
            if ($null -ne $tagProp) {
                $filter = [string]$tagProp.Value
            }
            if ([string]::IsNullOrWhiteSpace($filter)) {
                if ($next.Derived.VisibleFilters.Count -eq 0) {
                    return $next
                }
                $filter = [string]$next.Derived.VisibleFilters[$next.Cursor.FilterIndex].Name
            }

            if ($next.Query.SelectedFilters.Contains($filter)) {
                [void]$next.Query.SelectedFilters.Remove($filter)
            } else {
                [void]$next.Query.SelectedFilters.Add($filter)
            }

            $next.Cursor.ChangeIndex = 0
            $next.Cursor.ChangeScrollTop = 0
            $next = Update-BrowserDerivedState -State $next

            $targetFilterIndex = -1
            for ($i = 0; $i -lt $next.Derived.VisibleFilters.Count; $i++) {
                if ($next.Derived.VisibleFilters[$i].Name -eq $filter) {
                    $targetFilterIndex = $i
                    break
                }
            }
            if ($targetFilterIndex -ge 0) {
                $next.Cursor.FilterIndex = $targetFilterIndex
            }

            return Update-BrowserDerivedState -State $next
        }
        'ToggleHideUnavailableFilters' {
            $currentFilterName = $null
            if ($next.Cursor.FilterIndex -ge 0 -and $next.Cursor.FilterIndex -lt $next.Derived.VisibleFilters.Count) {
                $currentFilterName = [string]$next.Derived.VisibleFilters[$next.Cursor.FilterIndex].Name
            }

            $next.Ui.HideUnavailableFilters = -not $next.Ui.HideUnavailableFilters
            $next.Cursor.FilterIndex = 0
            $next.Cursor.FilterScrollTop = 0
            $next = Update-BrowserDerivedState -State $next

            if (-not [string]::IsNullOrWhiteSpace($currentFilterName)) {
                for ($i = 0; $i -lt $next.Derived.VisibleFilters.Count; $i++) {
                    if ($next.Derived.VisibleFilters[$i].Name -eq $currentFilterName) {
                        $next.Cursor.FilterIndex = $i
                        break
                    }
                }
            }

            return Update-BrowserDerivedState -State $next
        }
        'ToggleChangelistView' {
            $next.Ui.ExpandedChangelists = -not [bool]$next.Ui.ExpandedChangelists
            return Update-BrowserDerivedState -State $next
        }
        'Describe' {
            if ($next.Derived.VisibleChangeIds.Count -eq 0) { return $next }
            $idx = [Math]::Max(0, [Math]::Min($next.Cursor.ChangeIndex,
                                               $next.Derived.VisibleChangeIds.Count - 1))
            $next.Runtime.LastSelectedId = $next.Derived.VisibleChangeIds[$idx]
            $next.Runtime.DetailChangeId = $next.Derived.VisibleChangeIds[$idx]  # persists for rendering
            return Update-BrowserDerivedState -State $next
        }
        'DeleteChange' {
            $currentViewMode = if (($next.Ui.PSObject.Properties.Match('ViewMode')).Count -gt 0) { [string]$next.Ui.ViewMode } else { 'Pending' }
            if ($currentViewMode -eq 'Submitted') { return $next }  # No-op in submitted view
            if ($next.Derived.VisibleChangeIds.Count -eq 0) { return $next }
            $idx = [Math]::Max(0, [Math]::Min($next.Cursor.ChangeIndex,
                                               $next.Derived.VisibleChangeIds.Count - 1))
            $next.Runtime.DeleteChangeId = $next.Derived.VisibleChangeIds[$idx]
            return Update-BrowserDerivedState -State $next
        }
        'Reload' {
            $currentViewMode = if (($next.Ui.PSObject.Properties.Match('ViewMode')).Count -gt 0) { [string]$next.Ui.ViewMode } else { 'Pending' }
            $next.Data.DescribeCache = @{}
            $next.Runtime.LastSelectedId = $null
            $next.Runtime.DetailChangeId = $null
            if ($currentViewMode -eq 'Submitted') {
                $next.Runtime.SubmittedReloadRequested = $true
            } else {
                $next.Runtime.ReloadRequested = $true
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
        'SwitchView' {
            $targetView  = [string]$Action.View
            if ($targetView -ne 'Pending' -and $targetView -ne 'Submitted') { return $next }

            $currentView = if (($next.Ui.PSObject.Properties.Match('ViewMode')).Count -gt 0) { [string]$next.Ui.ViewMode } else { 'Pending' }
            if ($targetView -eq $currentView) { return $next }

            # Save current cursor snapshot
            if (($next.Cursor.PSObject.Properties.Match('ViewSnapshots')).Count -gt 0 -and $null -ne $next.Cursor.ViewSnapshots) {
                $next.Cursor.ViewSnapshots[$currentView] = @{
                    ChangeIndex     = $next.Cursor.ChangeIndex
                    ChangeScrollTop = $next.Cursor.ChangeScrollTop
                }
            }

            # Switch view mode
            $next.Ui.ViewMode = $targetView

            # Restore target view cursor snapshot
            if (($next.Cursor.PSObject.Properties.Match('ViewSnapshots')).Count -gt 0 -and $null -ne $next.Cursor.ViewSnapshots -and $next.Cursor.ViewSnapshots.ContainsKey($targetView)) {
                $snap = $next.Cursor.ViewSnapshots[$targetView]
                $next.Cursor.ChangeIndex     = [int]$snap.ChangeIndex
                $next.Cursor.ChangeScrollTop = [int]$snap.ChangeScrollTop
            } else {
                $next.Cursor.ChangeIndex     = 0
                $next.Cursor.ChangeScrollTop = 0
            }

            # Reset filter cursor and selected filters (different filter sets per view)
            $next.Cursor.FilterIndex     = 0
            $next.Cursor.FilterScrollTop = 0
            $next.Query.SelectedFilters.Clear()

            # If switching to submitted for the first time (empty list), request initial load
            if ($targetView -eq 'Submitted') {
                [object[]]$submittedChanges = @()
                if (($next.Data.PSObject.Properties.Match('SubmittedChanges')).Count -gt 0 -and $null -ne $next.Data.SubmittedChanges) {
                    $submittedChanges = @($next.Data.SubmittedChanges)
                }
                $submittedHasMore = if (($next.Data.PSObject.Properties.Match('SubmittedHasMore')).Count -gt 0) { [bool]$next.Data.SubmittedHasMore } else { $true }
                if ($submittedChanges.Count -eq 0 -and $submittedHasMore) {
                    $next.Runtime.LoadMoreRequested = $true
                }
            }

            return Update-BrowserDerivedState -State $next
        }
        'LoadMore' {
            $currentViewMode  = if (($next.Ui.PSObject.Properties.Match('ViewMode')).Count -gt 0) { [string]$next.Ui.ViewMode } else { 'Pending' }
            $submittedHasMore = if (($next.Data.PSObject.Properties.Match('SubmittedHasMore')).Count -gt 0) { [bool]$next.Data.SubmittedHasMore } else { $false }
            if ($currentViewMode -eq 'Submitted' -and $submittedHasMore) {
                $next.Runtime.LoadMoreRequested = $true
            }
            return $next
        }
        default {
            return Update-BrowserDerivedState -State $next
        }
    }
}

function ConvertTo-ChangeNumberFromId {
    param([string]$Id)
    if ($Id -match '^\d+$') { return [int]$Id }
    return $null
}

Export-ModuleMember -Function New-BrowserState, Copy-BrowserState, Invoke-BrowserReducer, Update-BrowserDerivedState, ConvertTo-ChangeNumberFromId, Get-ChangeInnerViewRows, Get-ChangeRowsPerItem, Get-ChangeViewCapacity
