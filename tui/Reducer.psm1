Set-StrictMode -Version Latest

$script:CommandHistoryMaxSize = 50
$script:CommandLogMaxSize     = 200
$script:BrowserGlobalActionTypes = @(
    'CommandStart', 'CommandFinish',
    'ToggleCommandModal', 'ShowCommandModal',
    'SwitchView',
    'Quit', 'Resize',
    'ToggleHelpOverlay', 'HideHelpOverlay',
    'LogCommandExecution'
)

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

function Copy-StateObject {
    <#
    .SYNOPSIS
        Generic deep copy for PSCustomObject state trees.
    .DESCRIPTION
        Recursively copies PSCustomObject properties.
        HashSet<string> values are copied into a new set with the same comparer.
        IDictionary values (hashtables / dictionaries) are kept as shared
        references — append-only caches such as DescribeCache and FileCache are
        large and safe to share across reducer calls.
        Arrays are copied into new arrays with each element recursively copied.
        Primitives are returned by value.
    #>
    param([AllowNull()]$Obj)

    if ($null -eq $Obj) { return $null }

    # Primitive scalars — returned by value
    if ($Obj -is [string] -or $Obj -is [int] -or $Obj -is [bool] -or
        $Obj -is [long]   -or $Obj -is [double] -or $Obj -is [datetime] -or
        $Obj -is [System.Enum]) {
        return $Obj
    }

    # HashSet<string> — copy into a new set preserving the comparer.
    # Use Write-Output -NoEnumerate to prevent PowerShell from unrolling an empty set to $null.
    if ($Obj -is [System.Collections.Generic.HashSet[string]]) {
        $newSet = [System.Collections.Generic.HashSet[string]]::new($Obj.Comparer)
        foreach ($item in $Obj) { [void]$newSet.Add($item) }
        Write-Output -NoEnumerate $newSet
        return
    }

    # IDictionary (Hashtable / Dictionary) — keep as shared reference.
    # Caches such as DescribeCache and FileCache are append-only, so sharing is safe.
    if ($Obj -is [System.Collections.IDictionary]) {
        return $Obj
    }

    # Array — shallow-copy the array container.
    # State arrays hold immutable scalars or reference objects that are replaced
    # wholesale rather than mutated in-place, so cloning each element is wasted
    # work on the reducer hot path.
    # Use Write-Output -NoEnumerate to prevent an empty array from being unrolled to $null.
    if ($Obj -is [array]) {
        Write-Output -NoEnumerate ($Obj.Clone())
        return
    }

    # PSCustomObject — new object with all NoteProperty values recursively copied.
    # Build a single ordered hashtable and cast once; this is substantially
    # faster than creating an empty PSCustomObject and appending properties with
    # Add-Member on every reducer action.
    if ($Obj -is [pscustomobject]) {
        $copyMap = [ordered]@{}
        foreach ($prop in $Obj.PSObject.Properties) {
            if ($prop.MemberType -eq 'NoteProperty') {
                $propCopy = Copy-StateObject -Obj $prop.Value
                # PowerShell scalar-izes single-item pipeline output; re-wrap arrays that
                # were collapsed to a scalar so state arrays such as ScreenStack survive
                # the copy without losing their [array] type.
                if ($prop.Value -is [array] -and $propCopy -isnot [array]) {
                    $propCopy = [object[]] @($propCopy)
                }
                $copyMap[$prop.Name] = $propCopy
            }
        }
        return [pscustomobject]$copyMap
    }

    # Fallback — return as-is for unknown reference types
    return $Obj
}

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
            # FileCache: keyed by "<Change>:<SourceKind>"; append-only, shared across copies.
            FileCache         = @{}
            FilesSourceChange = $null
            FilesSourceKind   = ''
            CurrentUser       = ''
            CurrentClient     = ''
            SubmittedChanges  = @()
            SubmittedHasMore  = $true
            SubmittedOldestId = $null
            # CommandOutputCache: keyed by CommandId (string); append-only, shared across copies.
            CommandOutputCache = @{}
        }
        Ui = [pscustomobject]@{
            ActivePane             = 'Filters'
            # ScreenStack: active screen is always ScreenStack[-1].
            ScreenStack            = @('Changelists')
            IsMaximized            = $false
            HideUnavailableFilters = $false
            ExpandedChangelists    = $false
            ViewMode               = 'Pending'
            Layout                 = Get-BrowserLayout -Width $InitialWidth -Height $InitialHeight
            ExpandedCommands       = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        }
        Query = [pscustomobject]@{
            SelectedFilters  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            MarkedChangeIds  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            SearchText       = ''
            SearchMode       = 'None'
            SortMode         = 'Default'
            FileFilterTokens = @()   # parsed token list; see Step 4
            FileFilterText   = ''    # raw text for display
        }
        Derived = [pscustomobject]@{
            VisibleChangeIds      = @()
            VisibleFilters        = @()
            VisibleFileIndices    = @()  # int[] indices into FileCache entry
            VisibleCommandIds     = @()  # CommandId strings for CommandLog view
            VisibleCommandFilters = @()  # filter items for CommandLog left pane
        }
        Cursor = [pscustomobject]@{
            FilterIndex       = 0
            FilterScrollTop   = 0
            ChangeIndex       = 0
            ChangeScrollTop   = 0
            FileIndex         = 0
            FileScrollTop     = 0
            CommandIndex      = 0
            CommandScrollTop  = 0
            OutputIndex       = 0
            OutputScrollTop   = 0
            ViewSnapshots     = [pscustomobject]@{
                Pending    = [pscustomobject]@{ ChangeIndex = 0; ChangeScrollTop = 0 }
                Submitted  = [pscustomobject]@{ ChangeIndex = 0; ChangeScrollTop = 0 }
                CommandLog = [pscustomobject]@{ CommandIndex = 0; CommandScrollTop = 0 }
            }
        }
        Runtime = [pscustomobject]@{
            IsRunning      = $true
            LastError      = $null
            DetailChangeId = $null
            PendingRequest = $null
            ConfiguredMax  = 200
            HelpOverlayOpen          = $false
            NextCommandId            = 1
            CommandLog               = @()
            CommandOutputCommandId   = $null
            ModalPrompt              = [pscustomobject]@{
                IsOpen         = $false
                IsBusy         = $false
                Purpose        = 'Command'
                CurrentCommand = ''
                History        = @()
            }
        }
    }

    return Update-BrowserDerivedState -State $state
}

function Copy-BrowserState {
    <#
    .SYNOPSIS
        Deep-copies the browser state.
    .DESCRIPTION
        Delegates to Copy-StateObject for a generic recursive copy.
        IDictionary values (DescribeCache, FileCache, etc.) are kept as shared
        references because they are append-only and potentially large.
    #>
    param([Parameter(Mandatory = $true)]$State)
    return Copy-StateObject -Obj $State
}

function Get-CommandOutputCount {
    <#
    .SYNOPSIS
        Returns the number of formatted output lines for the currently viewed command.
    #>
    param($State)
    $cmdId = ''
    $cidProp = $State.Runtime.PSObject.Properties['CommandOutputCommandId']
    if ($null -ne $cidProp -and $null -ne $cidProp.Value) { $cmdId = [string]$cidProp.Value }
    if ([string]::IsNullOrEmpty($cmdId)) { return 0 }
    $cache = $State.Data.PSObject.Properties['CommandOutputCache']?.Value
    if ($null -eq $cache -or -not $cache.ContainsKey($cmdId)) { return 0 }
    return @($cache[$cmdId]).Count
}

function Get-OutputViewportSize {
    param($State)
    if ($null -ne $State.Ui.Layout -and $State.Ui.Layout.Mode -eq 'Normal') {
        return [Math]::Max(1, $State.Ui.Layout.ListPane.H - 2)
    }
    return 10
}

function Update-OutputDerivedState {
    param($State)
    $outputCount = Get-CommandOutputCount -State $State
    $viewport    = Get-OutputViewportSize  -State $State

    if ($outputCount -eq 0) {
        $State.Cursor.OutputIndex     = 0
        $State.Cursor.OutputScrollTop = 0
        return $State
    }

    if ($State.Cursor.OutputIndex -lt 0)             { $State.Cursor.OutputIndex = 0 }
    if ($State.Cursor.OutputIndex -ge $outputCount)  { $State.Cursor.OutputIndex = $outputCount - 1 }
    $maxScroll = [Math]::Max(0, $outputCount - $viewport)
    if ($State.Cursor.OutputScrollTop -lt 0)         { $State.Cursor.OutputScrollTop = 0 }
    if ($State.Cursor.OutputScrollTop -gt $maxScroll){ $State.Cursor.OutputScrollTop = $maxScroll }
    if ($State.Cursor.OutputIndex -lt $State.Cursor.OutputScrollTop) {
        $State.Cursor.OutputScrollTop = $State.Cursor.OutputIndex
    }
    if ($State.Cursor.OutputIndex -ge ($State.Cursor.OutputScrollTop + $viewport)) {
        $State.Cursor.OutputScrollTop = [Math]::Max(0, $State.Cursor.OutputIndex - $viewport + 1)
    }
    return $State
}

function Update-CommandLogDerivedState {
    <#
    .SYNOPSIS
        Computes derived state for the CommandLog view mode.
    .DESCRIPTION
        Called by Update-BrowserDerivedState when ViewMode -eq 'CommandLog'.
        Computes VisibleCommandIds, VisibleCommandFilters, and VisibleFilters.
        Clamps CommandIndex/CommandScrollTop and FilterIndex/FilterScrollTop.
    #>
    param([Parameter(Mandatory = $true)]$State)

    # Get CommandLog (newest first in storage)
    $commandLog = @()
    $clProp = $State.Runtime.PSObject.Properties['CommandLog']
    if ($null -ne $clProp -and $null -ne $clProp.Value) {
        $commandLog = @($clProp.Value)
    }

    # Get predicates keyed by filter name
    $predicates     = Get-CommandLogFilterPredicates -CommandLog $commandLog
    $allFilterNames = @($predicates.Keys)
    $State.Data.AllFilters = $allFilterNames

    # Compute VisibleCommandIds — oldest first (reverse of storage)
    $selectedFilters = $State.Query.SelectedFilters
    $visibleIds = [System.Collections.Generic.List[string]]::new()
    for ($i = $commandLog.Count - 1; $i -ge 0; $i--) {
        $entry   = $commandLog[$i]
        $passes  = $true
        foreach ($filter in $selectedFilters) {
            $pred = $predicates[$filter]
            if ($null -ne $pred -and -not ([bool](& $pred $entry))) {
                $passes = $false
                break
            }
        }
        if ($passes) { [void]$visibleIds.Add([string]$entry.CommandId) }
    }
    [object[]]$visibleCommandIds = @($visibleIds.ToArray())
    $State.Derived.VisibleCommandIds = $visibleCommandIds

    # Compute filter items (same shape as VisibleFilters so filter pane reuse works)
    $filterItems = [System.Collections.Generic.List[object]]::new()
    foreach ($filterName in $allFilterNames) {
        $matchCount = 0
        foreach ($entry in $commandLog) {
            $pred = $predicates[$filterName]
            if ($null -ne $pred -and [bool](& $pred $entry)) { $matchCount++ }
        }
        $isSelected   = $selectedFilters.Contains($filterName)
        $filterItems.Add([pscustomobject]@{
            Name        = $filterName
            MatchCount  = $matchCount
            IsSelected  = $isSelected
            IsSelectable = ($isSelected -or ($matchCount -gt 0))
        }) | Out-Null
    }
    $allCommandFilters = @($filterItems.ToArray())
    $State.Derived.VisibleFilters        = $allCommandFilters
    $State.Derived.VisibleCommandFilters = $allCommandFilters

    # Clamp FilterIndex / FilterScrollTop
    $filterViewport = 1
    if ($null -ne $State.Ui.Layout -and $State.Ui.Layout.Mode -eq 'Normal') {
        $filterViewport = [Math]::Max(1, $State.Ui.Layout.FilterPane.H - 2)
    }
    $filterCount = $allCommandFilters.Count
    if ($filterCount -eq 0) {
        $State.Cursor.FilterIndex     = 0
        $State.Cursor.FilterScrollTop = 0
    } else {
        if ($State.Cursor.FilterIndex -lt 0)              { $State.Cursor.FilterIndex = 0 }
        if ($State.Cursor.FilterIndex -ge $filterCount)   { $State.Cursor.FilterIndex = $filterCount - 1 }
        $maxFilterScroll = [Math]::Max(0, $filterCount - $filterViewport)
        if ($State.Cursor.FilterScrollTop -lt 0)          { $State.Cursor.FilterScrollTop = 0 }
        if ($State.Cursor.FilterScrollTop -gt $maxFilterScroll) { $State.Cursor.FilterScrollTop = $maxFilterScroll }
        if ($State.Cursor.FilterIndex -lt $State.Cursor.FilterScrollTop) {
            $State.Cursor.FilterScrollTop = $State.Cursor.FilterIndex
        }
        if ($State.Cursor.FilterIndex -ge ($State.Cursor.FilterScrollTop + $filterViewport)) {
            $State.Cursor.FilterScrollTop = [Math]::Max(0, $State.Cursor.FilterIndex - $filterViewport + 1)
        }
    }

    # Clamp CommandIndex / CommandScrollTop
    $commandCount = $visibleCommandIds.Count
    if ($commandCount -eq 0) {
        $State.Cursor.CommandIndex     = 0
        $State.Cursor.CommandScrollTop = 0
    } else {
        if ($State.Cursor.CommandIndex -lt 0)              { $State.Cursor.CommandIndex = 0 }
        if ($State.Cursor.CommandIndex -ge $commandCount)  { $State.Cursor.CommandIndex = $commandCount - 1 }
        $commandViewport = if ($null -ne $State.Ui.Layout -and $State.Ui.Layout.Mode -eq 'Normal') {
            [Math]::Max(1, $State.Ui.Layout.ListPane.H - 2)
        } else { 1 }
        $maxCommandScroll = [Math]::Max(0, $commandCount - $commandViewport)
        if ($State.Cursor.CommandScrollTop -lt 0)          { $State.Cursor.CommandScrollTop = 0 }
        if ($State.Cursor.CommandScrollTop -gt $maxCommandScroll) { $State.Cursor.CommandScrollTop = $maxCommandScroll }
        if ($State.Cursor.CommandIndex -lt $State.Cursor.CommandScrollTop) {
            $State.Cursor.CommandScrollTop = $State.Cursor.CommandIndex
        }
        if ($State.Cursor.CommandIndex -ge ($State.Cursor.CommandScrollTop + $commandViewport)) {
            $State.Cursor.CommandScrollTop = [Math]::Max(0, $State.Cursor.CommandIndex - $commandViewport + 1)
        }
    }

    # Safety: CommandLog mode does not display changelists
    $State.Derived.VisibleChangeIds   = @()
    $State.Derived.VisibleFileIndices = @()

    return $State
}

function Update-BrowserDerivedState {
    param([Parameter(Mandatory = $true)]$State)

    # Determine active source list and view context
    $viewMode    = if (($State.Ui.PSObject.Properties.Match('ViewMode')).Count -gt 0) { [string]$State.Ui.ViewMode } else { 'Pending' }
    $currentUser = if (($State.Data.PSObject.Properties.Match('CurrentUser')).Count -gt 0) { [string]$State.Data.CurrentUser } else { '' }

    # CommandLog mode has entirely separate derived state — return early.
    if ($viewMode -eq 'CommandLog') {
        return Update-CommandLogDerivedState -State $State
    }

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

    # ── Files screen derived state ────────────────────────────────────────────
    # Compute VisibleFileIndices from the cached file list.
    # Filter token application is deferred to Step 4; for now all loaded entries
    # are visible.
    $fileCache      = $State.Data.PSObject.Properties['FileCache']?.Value
    $sourceChangeProp = $State.Data.PSObject.Properties['FilesSourceChange']
    $sourceKindProp   = $State.Data.PSObject.Properties['FilesSourceKind']
    if ($null -ne $fileCache -and $null -ne $sourceChangeProp -and $null -ne $sourceKindProp) {
        $cacheKey = "$($sourceChangeProp.Value)`:$($sourceKindProp.Value)"
        if ($null -ne $sourceChangeProp.Value -and
            -not [string]::IsNullOrEmpty([string]$sourceKindProp.Value) -and
            $fileCache.ContainsKey($cacheKey)) {
            $allFiles = @($fileCache[$cacheKey])
            if ($allFiles.Count -gt 0) {
                $State.Derived.VisibleFileIndices = @(0..($allFiles.Count - 1))
            } else {
                $State.Derived.VisibleFileIndices = @()
            }
        } else {
            $State.Derived.VisibleFileIndices = @()
        }
    } elseif (($State.Derived.PSObject.Properties.Match('VisibleFileIndices')).Count -gt 0) {
        $State.Derived.VisibleFileIndices = @()
    }

    # Clamp FileIndex and FileScrollTop within the visible file list.
    if (($State.Cursor.PSObject.Properties.Match('FileIndex')).Count -gt 0) {
        $fileCount = if (($State.Derived.PSObject.Properties.Match('VisibleFileIndices')).Count -gt 0) {
            $State.Derived.VisibleFileIndices.Count
        } else { 0 }

        if ($fileCount -eq 0) {
            $State.Cursor.FileIndex     = 0
            $State.Cursor.FileScrollTop = 0
        } else {
            if ($State.Cursor.FileIndex -lt 0) { $State.Cursor.FileIndex = 0 }
            if ($State.Cursor.FileIndex -ge $fileCount) { $State.Cursor.FileIndex = $fileCount - 1 }

            $fileViewport  = if ($null -ne $State.Ui.Layout -and $State.Ui.Layout.Mode -eq 'Normal') {
                [Math]::Max(1, $State.Ui.Layout.ListPane.H - 2)
            } else { 1 }
            $maxFileScroll = [Math]::Max(0, $fileCount - $fileViewport)
            if ($State.Cursor.FileScrollTop -lt 0) { $State.Cursor.FileScrollTop = 0 }
            if ($State.Cursor.FileScrollTop -gt $maxFileScroll) { $State.Cursor.FileScrollTop = $maxFileScroll }
            if ($State.Cursor.FileIndex -lt $State.Cursor.FileScrollTop) {
                $State.Cursor.FileScrollTop = $State.Cursor.FileIndex
            }
            if ($State.Cursor.FileIndex -ge ($State.Cursor.FileScrollTop + $fileViewport)) {
                $State.Cursor.FileScrollTop = [Math]::Max(0, $State.Cursor.FileIndex - $fileViewport + 1)
            }
        }
    }

    return $State
}

function Get-FilterViewportSize {
    param($CurrentState)
    if ($CurrentState.Ui.Layout -and $CurrentState.Ui.Layout.Mode -eq 'Normal') {
        return [Math]::Max(1, $CurrentState.Ui.Layout.FilterPane.H - 2)
    }
    return 1
}

function Test-IsBrowserGlobalAction {
    param([Parameter(Mandatory = $true)][string]$ActionType)
    return ($ActionType -in $script:BrowserGlobalActionTypes)
}

function Get-ChangeViewportSize {
    param($CurrentState)
    return Get-ChangeViewCapacity -State $CurrentState
}

function Invoke-ChangelistReducer {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$Action
    )

    $next = Copy-BrowserState -State $State
    $currentViewMode = if (($next.Ui.PSObject.Properties.Match('ViewMode')).Count -gt 0) { [string]$next.Ui.ViewMode } else { 'Pending' }

    switch ($Action.Type) {
        'CommandStart' {
            $next.Runtime.ModalPrompt.IsBusy         = $true
            $next.Runtime.ModalPrompt.IsOpen         = $true
            $next.Runtime.ModalPrompt.Purpose        = 'Command'
            $next.Runtime.ModalPrompt.CurrentCommand = [string]$Action.CommandLine
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
            $trimmed = @($historyItem) + @($next.Runtime.ModalPrompt.History |
                Select-Object -First ($script:CommandHistoryMaxSize - 1))
            $next.Runtime.ModalPrompt.History        = $trimmed
            $next.Runtime.ModalPrompt.IsBusy         = $false
            $next.Runtime.ModalPrompt.CurrentCommand = ''
            if ($succeeded) {
                $next.Runtime.ModalPrompt.IsOpen = $false
            }
            return $next
        }
        'ShowCommandModal' {
            $next.Runtime.ModalPrompt.IsOpen = $true
            return $next
        }
        'ToggleCommandModal' {
            if (-not $next.Runtime.ModalPrompt.IsBusy) {
                $next.Runtime.ModalPrompt.IsOpen = -not $next.Runtime.ModalPrompt.IsOpen
            }
            return $next
        }
        'HideCommandModal' {
            # Escape: close help overlay first; then close modal prompt on second press
            if ($next.Runtime.HelpOverlayOpen) {
                $next.Runtime.HelpOverlayOpen = $false
                return $next
            }
            if (-not $next.Runtime.ModalPrompt.IsBusy) {
                $next.Runtime.ModalPrompt.IsOpen = $false
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
            } elseif ($currentViewMode -eq 'CommandLog') {
                if (($next.Cursor.PSObject.Properties.Match('CommandIndex')).Count -gt 0 -and $next.Cursor.CommandIndex -gt 0) {
                    $next.Cursor.CommandIndex--
                }
            } else {
                if ($next.Cursor.ChangeIndex -gt 0) { $next.Cursor.ChangeIndex-- }
            }
            return Update-BrowserDerivedState -State $next
        }
        'MoveDown' {
            if ($next.Ui.ActivePane -eq 'Filters') {
                $maxFilterIndex = [Math]::Max(0, $next.Derived.VisibleFilters.Count - 1)
                if ($next.Cursor.FilterIndex -lt $maxFilterIndex) { $next.Cursor.FilterIndex++ }
            } elseif ($currentViewMode -eq 'CommandLog') {
                if (($next.Cursor.PSObject.Properties.Match('CommandIndex')).Count -gt 0 -and ($next.Derived.PSObject.Properties.Match('VisibleCommandIds')).Count -gt 0) {
                    $maxIdx = [Math]::Max(0, $next.Derived.VisibleCommandIds.Count - 1)
                    if ($next.Cursor.CommandIndex -lt $maxIdx) { $next.Cursor.CommandIndex++ }
                }
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
            } elseif ($currentViewMode -eq 'CommandLog') {
                if (($next.Cursor.PSObject.Properties.Match('CommandIndex')).Count -gt 0) {
                    $step = Get-ChangeViewportSize -CurrentState $next
                    $next.Cursor.CommandIndex = [Math]::Max(0, $next.Cursor.CommandIndex - $step)
                }
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
            } elseif ($currentViewMode -eq 'CommandLog') {
                if (($next.Cursor.PSObject.Properties.Match('CommandIndex')).Count -gt 0 -and ($next.Derived.PSObject.Properties.Match('VisibleCommandIds')).Count -gt 0) {
                    $step = Get-ChangeViewportSize -CurrentState $next
                    $maxIdx = [Math]::Max(0, $next.Derived.VisibleCommandIds.Count - 1)
                    $next.Cursor.CommandIndex = [Math]::Min($maxIdx, $next.Cursor.CommandIndex + $step)
                }
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
            } elseif ($currentViewMode -eq 'CommandLog') {
                if (($next.Cursor.PSObject.Properties.Match('CommandIndex')).Count -gt 0) {
                    $next.Cursor.CommandIndex     = 0
                    $next.Cursor.CommandScrollTop = 0
                }
            } else {
                $next.Cursor.ChangeIndex = 0
                $next.Cursor.ChangeScrollTop = 0
            }
            return Update-BrowserDerivedState -State $next
        }
        'MoveEnd' {
            if ($next.Ui.ActivePane -eq 'Filters') {
                $next.Cursor.FilterIndex = [Math]::Max(0, $next.Derived.VisibleFilters.Count - 1)
            } elseif ($currentViewMode -eq 'CommandLog') {
                if (($next.Cursor.PSObject.Properties.Match('CommandIndex')).Count -gt 0 -and ($next.Derived.PSObject.Properties.Match('VisibleCommandIds')).Count -gt 0) {
                    $next.Cursor.CommandIndex = [Math]::Max(0, $next.Derived.VisibleCommandIds.Count - 1)
                }
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
            if ($currentViewMode -eq 'CommandLog') {
                # In CommandLog mode, toggle expand for the selected command
                $expandedProp = $next.Ui.PSObject.Properties['ExpandedCommands']
                if ($null -ne $expandedProp -and ($next.Derived.PSObject.Properties.Match('VisibleCommandIds')).Count -gt 0 -and $next.Derived.VisibleCommandIds.Count -gt 0) {
                    $idx    = [Math]::Max(0, [Math]::Min($next.Cursor.CommandIndex, $next.Derived.VisibleCommandIds.Count - 1))
                    $cmdId  = [string]$next.Derived.VisibleCommandIds[$idx]
                    $expSet = $next.Ui.ExpandedCommands
                    if ($expSet.Contains($cmdId)) {
                        [void]$expSet.Remove($cmdId)
                    } else {
                        [void]$expSet.Add($cmdId)
                    }
                }
            } else {
                $next.Ui.ExpandedChangelists = -not [bool]$next.Ui.ExpandedChangelists
            }
            return Update-BrowserDerivedState -State $next
        }
        'Describe' {
            if ($next.Derived.VisibleChangeIds.Count -eq 0) { return $next }
            $idx = [Math]::Max(0, [Math]::Min($next.Cursor.ChangeIndex,
                                               $next.Derived.VisibleChangeIds.Count - 1))
            $changeId = $next.Derived.VisibleChangeIds[$idx]
            $next.Runtime.PendingRequest = [pscustomobject]@{ Kind = 'FetchDescribe'; ChangeId = $changeId }
            $next.Runtime.DetailChangeId = $changeId  # persists for rendering
            return Update-BrowserDerivedState -State $next
        }
        'DeleteChange' {
            $currentViewMode = if (($next.Ui.PSObject.Properties.Match('ViewMode')).Count -gt 0) { [string]$next.Ui.ViewMode } else { 'Pending' }
            if ($currentViewMode -eq 'Submitted') { return $next }  # No-op in submitted view
            if ($next.Derived.VisibleChangeIds.Count -eq 0) { return $next }
            $idx = [Math]::Max(0, [Math]::Min($next.Cursor.ChangeIndex,
                                               $next.Derived.VisibleChangeIds.Count - 1))
            $next.Runtime.PendingRequest = [pscustomobject]@{ Kind = 'DeleteChange'; ChangeId = $next.Derived.VisibleChangeIds[$idx] }
            return Update-BrowserDerivedState -State $next
        }
        'ToggleMarkCurrent' {
            if ($next.Derived.VisibleChangeIds.Count -eq 0) { return $next }
            $idx     = [Math]::Max(0, [Math]::Min($next.Cursor.ChangeIndex, $next.Derived.VisibleChangeIds.Count - 1))
            $changeId = [string]$next.Derived.VisibleChangeIds[$idx]
            $markedProp = $next.Query.PSObject.Properties['MarkedChangeIds']
            if ($null -ne $markedProp -and $null -ne $markedProp.Value) {
                $marked = $markedProp.Value
                if ($marked.Contains($changeId)) {
                    [void]$marked.Remove($changeId)
                } else {
                    [void]$marked.Add($changeId)
                }
            }
            return $next
        }
        'MarkAllVisible' {
            $markedProp = $next.Query.PSObject.Properties['MarkedChangeIds']
            if ($null -ne $markedProp -and $null -ne $markedProp.Value) {
                $marked = $markedProp.Value
                foreach ($id in $next.Derived.VisibleChangeIds) {
                    [void]$marked.Add([string]$id)
                }
            }
            return $next
        }
        'ClearMarks' {
            $markedProp = $next.Query.PSObject.Properties['MarkedChangeIds']
            if ($null -ne $markedProp -and $null -ne $markedProp.Value) {
                $next.Query.MarkedChangeIds.Clear()
            }
            return $next
        }
        'Reload' {
            $currentViewMode = if (($next.Ui.PSObject.Properties.Match('ViewMode')).Count -gt 0) { [string]$next.Ui.ViewMode } else { 'Pending' }
            $next.Data.DescribeCache = @{}
            $next.Runtime.DetailChangeId = $null
            if ($currentViewMode -eq 'Submitted') {
                $next.Runtime.PendingRequest = [pscustomobject]@{ Kind = 'ReloadSubmitted' }
            } else {
                $next.Runtime.PendingRequest = [pscustomobject]@{ Kind = 'ReloadPending' }
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
            if ($targetView -ne 'Pending' -and $targetView -ne 'Submitted' -and $targetView -ne 'CommandLog') { return $next }

            $currentView = if (($next.Ui.PSObject.Properties.Match('ViewMode')).Count -gt 0) { [string]$next.Ui.ViewMode } else { 'Pending' }
            if ($targetView -eq $currentView) { return $next }

            # If on a pushed screen (Files/CommandOutput), pop back to Changelists first.
            [object[]]$currentStack = if (($next.Ui.PSObject.Properties.Match('ScreenStack')).Count -gt 0 -and $null -ne $next.Ui.ScreenStack) { @($next.Ui.ScreenStack) } else { @('Changelists') }
            if ($currentStack.Count -gt 1) {
                $next.Ui.ScreenStack = @('Changelists')
            }

            # Save current cursor snapshot
            if (($next.Cursor.PSObject.Properties.Match('ViewSnapshots')).Count -gt 0 -and $null -ne $next.Cursor.ViewSnapshots) {
                if ($currentView -eq 'CommandLog') {
                    if (($next.Cursor.PSObject.Properties.Match('CommandIndex')).Count -gt 0) {
                        $next.Cursor.ViewSnapshots.CommandLog = [pscustomobject]@{
                            CommandIndex     = $next.Cursor.CommandIndex
                            CommandScrollTop = $next.Cursor.CommandScrollTop
                        }
                    }
                } else {
                    $next.Cursor.ViewSnapshots.$currentView = [pscustomobject]@{
                        ChangeIndex     = $next.Cursor.ChangeIndex
                        ChangeScrollTop = $next.Cursor.ChangeScrollTop
                    }
                }
            }

            # Switch view mode
            $next.Ui.ViewMode = $targetView

            # Restore target view cursor snapshot
            if (($next.Cursor.PSObject.Properties.Match('ViewSnapshots')).Count -gt 0 -and $null -ne $next.Cursor.ViewSnapshots) {
                if ($targetView -eq 'CommandLog') {
                    $snap = $next.Cursor.ViewSnapshots.CommandLog
                    if ($null -ne $snap -and ($snap.PSObject.Properties.Match('CommandIndex')).Count -gt 0) {
                        $next.Cursor.CommandIndex     = [int]$snap.CommandIndex
                        $next.Cursor.CommandScrollTop = [int]$snap.CommandScrollTop
                    } else {
                        $next.Cursor.CommandIndex     = 0
                        $next.Cursor.CommandScrollTop = 0
                    }
                } elseif (($next.Cursor.ViewSnapshots.PSObject.Properties.Match($targetView)).Count -gt 0) {
                    $snap = $next.Cursor.ViewSnapshots.$targetView
                    $next.Cursor.ChangeIndex     = [int]$snap.ChangeIndex
                    $next.Cursor.ChangeScrollTop = [int]$snap.ChangeScrollTop
                } else {
                    $next.Cursor.ChangeIndex     = 0
                    $next.Cursor.ChangeScrollTop = 0
                }
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
                    $next.Runtime.PendingRequest = [pscustomobject]@{ Kind = 'LoadMore' }
                }
            }

            return Update-BrowserDerivedState -State $next
        }
        'LoadMore' {
            $currentViewMode  = if (($next.Ui.PSObject.Properties.Match('ViewMode')).Count -gt 0) { [string]$next.Ui.ViewMode } else { 'Pending' }
            $submittedHasMore = if (($next.Data.PSObject.Properties.Match('SubmittedHasMore')).Count -gt 0) { [bool]$next.Data.SubmittedHasMore } else { $false }
            if ($currentViewMode -eq 'Submitted' -and $submittedHasMore) {
                $next.Runtime.PendingRequest = [pscustomobject]@{ Kind = 'LoadMore' }
            }
            return $next
        }
        'LogCommandExecution' {
            # Assign next monotonic CommandId
            $cmdIdInt = if (($next.Runtime.PSObject.Properties.Match('NextCommandId')).Count -gt 0) { [int]$next.Runtime.NextCommandId } else { 1 }
            $cmdId    = [string]$cmdIdInt
            $next.Runtime.NextCommandId = $cmdIdInt + 1

            # Build metadata item (no FormattedLines — those go into CommandOutputCache)
            $startedAt  = [datetime]$Action.StartedAt
            $endedAt    = [datetime]$Action.EndedAt
            $durationMs = [int](($endedAt - $startedAt).TotalMilliseconds)
            $metaItem   = [pscustomobject]@{
                CommandId   = $cmdId
                StartedAt   = $startedAt
                EndedAt     = $endedAt
                CommandLine = [string]$Action.CommandLine
                ExitCode    = [int]$Action.ExitCode
                Succeeded   = [bool]$Action.Succeeded
                ErrorText   = [string]$Action.ErrorText
                DurationMs  = $durationMs
                OutputCount = [int]$Action.OutputCount
                SummaryLine = [string]$Action.SummaryLine
                OutputRef   = $cmdId
            }

            # Store formatted lines in CommandOutputCache (shared dictionary)
            $formattedLines = @()
            $flProp = $Action.PSObject.Properties['FormattedLines']
            if ($null -ne $flProp -and $null -ne $flProp.Value) { $formattedLines = @($flProp.Value) }
            $next.Data.CommandOutputCache[$cmdId] = $formattedLines

            # Prepend metadata to CommandLog (newest first) and trim if over limit
            $newLog = @($metaItem) + @($next.Runtime.CommandLog)
            if ($newLog.Count -gt $script:CommandLogMaxSize) {
                $evicted = $newLog[$script:CommandLogMaxSize..($newLog.Count - 1)]
                foreach ($e in $evicted) {
                    $evKey = [string]$e.OutputRef
                    if (-not [string]::IsNullOrEmpty($evKey) -and $next.Data.CommandOutputCache.ContainsKey($evKey)) {
                        $next.Data.CommandOutputCache.Remove($evKey) | Out-Null
                    }
                }
                $newLog = $newLog[0..($script:CommandLogMaxSize - 1)]
            }
            $next.Runtime.CommandLog = $newLog

            return Update-BrowserDerivedState -State $next
        }
        'OpenFilesScreen' {
            # In CommandLog mode, open the CommandOutput screen for the selected command.
            if ($currentViewMode -eq 'CommandLog') {
                if (($next.Derived.PSObject.Properties.Match('VisibleCommandIds')).Count -gt 0 -and $next.Derived.VisibleCommandIds.Count -gt 0) {
                    $idx   = [Math]::Max(0, [Math]::Min($next.Cursor.CommandIndex, $next.Derived.VisibleCommandIds.Count - 1))
                    $cmdId = [string]$next.Derived.VisibleCommandIds[$idx]
                    [object[]]$currentStack = if (($next.Ui.PSObject.Properties.Match('ScreenStack')).Count -gt 0 -and $null -ne $next.Ui.ScreenStack) { @($next.Ui.ScreenStack) } else { @('Changelists') }
                    $next.Ui.ScreenStack = $currentStack + @('CommandOutput')
                    $next.Runtime.CommandOutputCommandId = $cmdId
                    $next.Cursor.OutputIndex     = 0
                    $next.Cursor.OutputScrollTop = 0
                }
                return Update-BrowserDerivedState -State $next
            }

            if ($next.Derived.VisibleChangeIds.Count -eq 0) { return $next }
            $idx         = [Math]::Max(0, [Math]::Min($next.Cursor.ChangeIndex, $next.Derived.VisibleChangeIds.Count - 1))
            $changeIdStr = $next.Derived.VisibleChangeIds[$idx]
            $change      = if ($changeIdStr -match '^\d+$') { [int]$changeIdStr } else { 0 }
            $viewMode    = if (($next.Ui.PSObject.Properties.Match('ViewMode')).Count -gt 0) { [string]$next.Ui.ViewMode } else { 'Pending' }
            $sourceKind  = if ($viewMode -eq 'Submitted') { 'Submitted' } else { 'Opened' }

            # Push Files onto the screen stack.
            # Use [object[]] to prevent PowerShell from scalar-izing a 1-element if-expression result.
            [object[]]$currentStack = if (($next.Ui.PSObject.Properties.Match('ScreenStack')).Count -gt 0 -and $null -ne $next.Ui.ScreenStack) { @($next.Ui.ScreenStack) } else { @('Changelists') }
            $next.Ui.ScreenStack    = $currentStack + @('Files')

            # Record which CL and source kind to load (I/O side effect in Step 2).
            $next.Data.FilesSourceChange = $change
            $next.Data.FilesSourceKind   = $sourceKind

            # Clear stale file filter state and reset file cursor.
            $next.Query.FileFilterText   = ''
            $next.Query.FileFilterTokens = @()
            $next.Cursor.FileIndex       = 0
            $next.Cursor.FileScrollTop   = 0

            # Signal main loop to trigger the I/O side effect (implemented in Step 2).
            $next.Runtime.PendingRequest = [pscustomobject]@{ Kind = 'LoadFiles' }

            return Update-BrowserDerivedState -State $next
        }
        default {
            return Update-BrowserDerivedState -State $next
        }
    }
}

function Invoke-FilesReducer {
    <#
    .SYNOPSIS
        Reducer for the Files screen.  Handles files-screen-specific actions
        (navigation, CloseFilesScreen, SetFileFilter, Reload) and delegates
        cross-screen lifecycle actions (Quit, Resize, modal lifecycle) to
        Invoke-ChangelistReducer so the logic is not duplicated.
    #>
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$Action
    )

    # Delegate actions whose logic is identical on every screen.
    if (Test-IsBrowserGlobalAction -ActionType ([string]$Action.Type)) {
        return Invoke-ChangelistReducer -State $State -Action $Action
    }

    $next = Copy-BrowserState -State $State

    switch ($Action.Type) {
        'HideCommandModal' {
            # Esc priority: help overlay → command modal → close files screen.
            if ($next.Runtime.HelpOverlayOpen) {
                $next.Runtime.HelpOverlayOpen = $false
                return $next
            }
            if ($next.Runtime.ModalPrompt.IsOpen -and -not $next.Runtime.ModalPrompt.IsBusy) {
                $next.Runtime.ModalPrompt.IsOpen = $false
                return $next
            }
            # Fall through: Esc with no overlay open → close the files screen.
            $stack = [System.Collections.Generic.List[string]]::new()
            foreach ($s in @($next.Ui.ScreenStack)) { $stack.Add([string]$s) }
            if ($stack.Count -gt 1) { $stack.RemoveAt($stack.Count - 1) }
            $next.Ui.ScreenStack = $stack.ToArray()
            return Update-BrowserDerivedState -State $next
        }
        'CloseFilesScreen' {
            $stack = [System.Collections.Generic.List[string]]::new()
            foreach ($s in @($next.Ui.ScreenStack)) { $stack.Add([string]$s) }
            if ($stack.Count -gt 1) { $stack.RemoveAt($stack.Count - 1) }
            $next.Ui.ScreenStack = $stack.ToArray()
            return Update-BrowserDerivedState -State $next
        }
        'SwitchPane' {
            # Cycle between left (filter) and right (list) panes on the files screen.
            # Re-use 'Filters'/'Changelists' as stand-in values until the render layer
            # assigns file-specific pane names in a later step.
            if ($next.Ui.ActivePane -eq 'Filters') {
                $next.Ui.ActivePane = 'Changelists'
            } else {
                $next.Ui.ActivePane = 'Filters'
            }
            return $next
        }
        'MoveUp' {
            if ($next.Cursor.FileIndex -gt 0) { $next.Cursor.FileIndex-- }
            return Update-BrowserDerivedState -State $next
        }
        'MoveDown' {
            $maxIdx = [Math]::Max(0, $next.Derived.VisibleFileIndices.Count - 1)
            if ($next.Cursor.FileIndex -lt $maxIdx) { $next.Cursor.FileIndex++ }
            return Update-BrowserDerivedState -State $next
        }
        'PageUp' {
            $step = if ($null -ne $next.Ui.Layout -and $next.Ui.Layout.Mode -eq 'Normal') {
                [Math]::Max(1, $next.Ui.Layout.ListPane.H - 2)
            } else { 10 }
            $next.Cursor.FileIndex = [Math]::Max(0, $next.Cursor.FileIndex - $step)
            return Update-BrowserDerivedState -State $next
        }
        'PageDown' {
            $step   = if ($null -ne $next.Ui.Layout -and $next.Ui.Layout.Mode -eq 'Normal') {
                [Math]::Max(1, $next.Ui.Layout.ListPane.H - 2)
            } else { 10 }
            $maxIdx = [Math]::Max(0, $next.Derived.VisibleFileIndices.Count - 1)
            $next.Cursor.FileIndex = [Math]::Min($maxIdx, $next.Cursor.FileIndex + $step)
            return Update-BrowserDerivedState -State $next
        }
        'MoveHome' {
            $next.Cursor.FileIndex     = 0
            $next.Cursor.FileScrollTop = 0
            return Update-BrowserDerivedState -State $next
        }
        'MoveEnd' {
            $next.Cursor.FileIndex = [Math]::Max(0, $next.Derived.VisibleFileIndices.Count - 1)
            return Update-BrowserDerivedState -State $next
        }
        'SetFileFilter' {
            # Stub — full parsing and filtering implemented in Step 4.
            $textProp = $Action.PSObject.Properties['FilterText']
            $text     = if ($null -ne $textProp) { [string]$textProp.Value } else { '' }
            $next.Query.FileFilterText   = $text
            $next.Query.FileFilterTokens = @()  # Step 4 will parse this
            $next.Cursor.FileIndex       = 0
            $next.Cursor.FileScrollTop   = 0
            return Update-BrowserDerivedState -State $next
        }
        'OpenFilterPrompt' {
            # Stub — full implementation in Step 4.
            return $next
        }
        'Reload' {
            # Evict the cache entry for the current file source so a fresh load is triggered.
            $cacheKey = "$($next.Data.FilesSourceChange)`:$($next.Data.FilesSourceKind)"
            $fileCache = $next.Data.PSObject.Properties['FileCache']?.Value
            if ($null -ne $fileCache -and $fileCache.ContainsKey($cacheKey)) {
                $fileCache.Remove($cacheKey) | Out-Null
            }
            $next.Runtime.PendingRequest = [pscustomobject]@{ Kind = 'LoadFiles' }
            return Update-BrowserDerivedState -State $next
        }
        'OpenFilesScreen' {
            # No-op: already on Files screen; cannot nest.
            return $next
        }
        default {
            return Update-BrowserDerivedState -State $next
        }
    }
}

function Invoke-CommandOutputReducer {
    <#
    .SYNOPSIS
        Reducer for the CommandOutput screen. Handles scrolling through formatted
        p4 command output and Escape/left-arrow to pop the screen.
    #>
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$Action
    )

    # Delegate global lifecycle actions to ChangelistReducer
    if (Test-IsBrowserGlobalAction -ActionType ([string]$Action.Type)) {
        return Invoke-ChangelistReducer -State $State -Action $Action
    }

    $next = Copy-BrowserState -State $State

    $closeScreen = {
        param($s)
        $stack = [System.Collections.Generic.List[string]]::new()
        foreach ($item in @($s.Ui.ScreenStack)) { $stack.Add([string]$item) }
        if ($stack.Count -gt 1) { $stack.RemoveAt($stack.Count - 1) }
        $s.Ui.ScreenStack = $stack.ToArray()
        return Update-BrowserDerivedState -State $s
    }

    switch ($Action.Type) {
        'HideCommandModal' {
            if ($next.Runtime.HelpOverlayOpen) {
                $next.Runtime.HelpOverlayOpen = $false
                return $next
            }
            if ($next.Runtime.ModalPrompt.IsOpen -and -not $next.Runtime.ModalPrompt.IsBusy) {
                $next.Runtime.ModalPrompt.IsOpen = $false
                return $next
            }
            return & $closeScreen $next
        }
        'CloseFilesScreen' {
            return & $closeScreen $next
        }
        'MoveUp' {
            if (($next.Cursor.PSObject.Properties.Match('OutputIndex')).Count -gt 0 -and $next.Cursor.OutputIndex -gt 0) {
                $next.Cursor.OutputIndex--
            }
            return Update-OutputDerivedState -State $next
        }
        'MoveDown' {
            $outputCount = Get-CommandOutputCount -State $next
            $maxIdx = [Math]::Max(0, $outputCount - 1)
            if (($next.Cursor.PSObject.Properties.Match('OutputIndex')).Count -gt 0 -and $next.Cursor.OutputIndex -lt $maxIdx) {
                $next.Cursor.OutputIndex++
            }
            return Update-OutputDerivedState -State $next
        }
        'PageUp' {
            $step = Get-OutputViewportSize -State $next
            if (($next.Cursor.PSObject.Properties.Match('OutputIndex')).Count -gt 0) {
                $next.Cursor.OutputIndex = [Math]::Max(0, $next.Cursor.OutputIndex - $step)
            }
            return Update-OutputDerivedState -State $next
        }
        'PageDown' {
            $step        = Get-OutputViewportSize -State $next
            $outputCount = Get-CommandOutputCount -State $next
            $maxIdx      = [Math]::Max(0, $outputCount - 1)
            if (($next.Cursor.PSObject.Properties.Match('OutputIndex')).Count -gt 0) {
                $next.Cursor.OutputIndex = [Math]::Min($maxIdx, $next.Cursor.OutputIndex + $step)
            }
            return Update-OutputDerivedState -State $next
        }
        'MoveHome' {
            if (($next.Cursor.PSObject.Properties.Match('OutputIndex')).Count -gt 0) {
                $next.Cursor.OutputIndex     = 0
                $next.Cursor.OutputScrollTop = 0
            }
            return Update-OutputDerivedState -State $next
        }
        'MoveEnd' {
            $outputCount = Get-CommandOutputCount -State $next
            if (($next.Cursor.PSObject.Properties.Match('OutputIndex')).Count -gt 0) {
                $next.Cursor.OutputIndex = [Math]::Max(0, $outputCount - 1)
            }
            return Update-OutputDerivedState -State $next
        }
        default {
            return Update-BrowserDerivedState -State $next
        }
    }
}

function Invoke-BrowserReducer {
    <#
    .SYNOPSIS
        Top-level reducer router.  Dispatches to Invoke-ChangelistReducer,
        Invoke-FilesReducer, or Invoke-CommandOutputReducer based on the
        active screen in Ui.ScreenStack.
    #>
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$Action
    )

    # Use PSObject.Properties index accessor — returns $null when property absent (safe for legacy test states).
    $screenStack  = $State.Ui.PSObject.Properties['ScreenStack']?.Value
    $activeScreen = if ($null -ne $screenStack -and $screenStack.Count -gt 0) { $screenStack[-1] } else { 'Changelists' }

    if ($activeScreen -eq 'Files') {
        return Invoke-FilesReducer -State $State -Action $Action
    }
    if ($activeScreen -eq 'CommandOutput') {
        return Invoke-CommandOutputReducer -State $State -Action $Action
    }
    return Invoke-ChangelistReducer -State $State -Action $Action
}

function ConvertTo-ChangeNumberFromId {
    param([string]$Id)
    if ($Id -match '^\d+$') { return [int]$Id }
    return $null
}

Export-ModuleMember -Function New-BrowserState, Copy-BrowserState, Copy-StateObject, `
    Invoke-BrowserReducer, Invoke-ChangelistReducer, Invoke-FilesReducer, Invoke-CommandOutputReducer, `
    Update-BrowserDerivedState, Update-CommandLogDerivedState, Update-OutputDerivedState, `
    Test-IsBrowserGlobalAction, `
    ConvertTo-ChangeNumberFromId, `
    Get-ChangeInnerViewRows, Get-ChangeRowsPerItem, Get-ChangeViewCapacity, `
    Get-CommandOutputCount, Get-OutputViewportSize
